/*
 * lemdconv.c
 * Leading Edge Model D -- PGM-to-LEMD image converter
 *
 * Converts a Netpbm PGM (P5 binary, 8-bit grayscale) image to the
 * Leading Edge Model D enhanced monochrome framebuffer format.
 *
 * Usage:
 *   lemdconv input.pgm output.lemd
 *
 * Build:
 *   cc -O2 -Wall -o lemdconv lemdconv.c
 *
 * --------------------------------------------------------------------
 * Output file format
 * --------------------------------------------------------------------
 * Exactly LEMD_TOTAL_BYTES (31,320) bytes, in display-ready LEMD
 * 4-bank interleave order:
 *
 *   Bank 0 (file offset     0): scanlines   0,  4,  8, ..., 344
 *   Bank 1 (file offset  7830): scanlines   1,  5,  9, ..., 345
 *   Bank 2 (file offset 15660): scanlines   2,  6, 10, ..., 346
 *   Bank 3 (file offset 23490): scanlines   3,  7, 11, ..., 347
 *
 * Each row is 90 bytes (720 pixels / 8 bits per byte).
 * Bit 7 of each byte is the leftmost pixel (MSB = left, per MDA/CGA).
 *
 * The DOS viewer (lemdshow.com) blits each bank with a single REP MOVSB
 * into 0xB000:0x0000, 0xB000:0x2000, 0xB000:0x4000, 0xB000:0x6000.
 *
 * --------------------------------------------------------------------
 * Pixel aspect ratio correction
 * --------------------------------------------------------------------
 * The LEMD display measures 4:3 physically and contains 720x348 pixels,
 * so pixels are NOT square.  Working out the ratio:
 *
 *   pixel width  : (4/3) / 720 = 1/540  of screen width
 *   pixel height :  (1)  / 348 = 1/348  of screen height
 *   pixel aspect (w:h)         = 348/540 = 29/45 ~= 0.644
 *
 * Each pixel is taller than it is wide.  A naive 720x348 source image
 * would render with everything stretched ~56% too wide.
 *
 * Correction: we use a 720x540 square-pixel virtual canvas as the
 * working space.  The source image is scaled into this canvas
 * (letterboxed or pillarboxed to preserve its aspect ratio), dithered
 * to 1-bit, then the 540 virtual rows are subsampled down to the 348
 * physical scanlines by taking the nearest-center source row for each
 * output row:
 *
 *   source_row(y) = (int)( (y + 0.5) * LEMD_VIRTUAL_H / LEMD_H )
 *                 = (int)( (y + 0.5) * 540.0 / 348.0 )
 *
 * If the first image displayed shows horizontal distortion:
 *   Wide faces  -> increase LEMD_VIRTUAL_H
 *   Narrow faces -> decrease LEMD_VIRTUAL_H
 *
 * --------------------------------------------------------------------
 * Dithering
 * --------------------------------------------------------------------
 * Floyd-Steinberg error diffusion in serpentine (boustrophedon) scan
 * order: left-to-right on even rows, right-to-left on odd rows.
 * Serpentine scanning reduces the directional horizontal streaking
 * that appears in standard (always left-to-right) Floyd-Steinberg.
 *
 * Error diffusion weights (standard Floyd-Steinberg):
 *   right neighbour :  7/16
 *   lower-left      :  3/16
 *   directly below  :  5/16
 *   lower-right     :  1/16
 *
 * On right-to-left rows the horizontal offsets are mirrored so that
 * "right" means toward the left edge of the screen -- the weights
 * themselves stay the same.
 *
 * --------------------------------------------------------------------
 * Input requirements
 * --------------------------------------------------------------------
 * PGM format: magic "P5", width, height, maxval=255, raw 8-bit pixels.
 * Any source dimensions are accepted.
 *
 * Recommended pre-processing with ImageMagick to control framing:
 *   convert photo.jpg -resize 720x540^ -gravity center \
 *           -extent 720x540 -colorspace Gray input.pgm
 * (The ^ modifier means "fill the target size", then -extent crops to it.)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <math.h>

/* -------------------------------------------------------------------------
 * LEMD physical framebuffer geometry
 * ------------------------------------------------------------------------- */
#define LEMD_W              720     /* pixels per scanline                   */
#define LEMD_H              348     /* physical scanlines                    */
#define LEMD_BANKS          4
#define LEMD_ROWS_PER_BANK  87      /* LEMD_H / LEMD_BANKS                  */
#define LEMD_STRIDE         90      /* bytes per row = LEMD_W / 8            */
#define LEMD_BANK_BYTES     (LEMD_ROWS_PER_BANK * LEMD_STRIDE)   /* 7830    */
#define LEMD_TOTAL_BYTES    (LEMD_BANKS * LEMD_BANK_BYTES)        /* 31320   */

/* -------------------------------------------------------------------------
 * Virtual canvas (square-pixel working space).
 * Derived from 4:3 physical display at 720x348:
 *   square-pixel height = 720 * (3/4) = 540
 * See aspect ratio discussion in file header above.
 * ------------------------------------------------------------------------- */
#define LEMD_VIRTUAL_H      540

/* -------------------------------------------------------------------------
 * Dither threshold: values >= this map to white (bit = 1).
 * 128 is the natural midpoint of [0,255].
 * ------------------------------------------------------------------------- */
#define THRESHOLD           128

/* =========================================================================
 * PGM reader
 * ========================================================================= */

/* Skip whitespace and '#'-introduced comment lines in a PGM header. */
static void pgm_skip_ws(FILE *f)
{
	int c;
	while ((c = fgetc(f)) != EOF) {
		if (c == '#') {
			while ((c = fgetc(f)) != EOF && c != '\n')
				;
		} else if (!isspace((unsigned char)c)) {
			ungetc(c, f);
			return;
		}
	}
}

/* Read one non-negative decimal integer from the PGM header. */
static int pgm_read_int(FILE *f)
{
	pgm_skip_ws(f);
	int c = fgetc(f);
	if (c == EOF || !isdigit((unsigned char)c)) return -1;
	int val = 0;
	while (c != EOF && isdigit((unsigned char)c)) {
		val = val * 10 + (c - '0');
		c   = fgetc(f);
	}
	if (c != EOF) ungetc(c, f);
	return val;
}

/*
 * pgm_read -- open and decode a P5 binary PGM file.
 *
 * Returns a heap-allocated flat row-major array of src_w * src_h bytes
 * (row 0 first, left-to-right within each row), or NULL on error.
 * Caller must free() the returned pointer.
 */
static unsigned char *pgm_read(const char *path, int *out_w, int *out_h)
{
	FILE *f = fopen(path, "rb");
	if (!f) {
		fprintf(stderr, "lemdconv: cannot open '%s': %s\n",
		        path, strerror(errno));
		return NULL;
	}

	char magic[3] = {0};
	if (fread(magic, 1, 2, f) != 2 || magic[0] != 'P' || magic[1] != '5') {
		fprintf(stderr, "lemdconv: '%s' is not a P5 binary PGM file\n", path);
		fclose(f);
		return NULL;
	}

	int w      = pgm_read_int(f);
	int h      = pgm_read_int(f);
	int maxval = pgm_read_int(f);
	fgetc(f);   /* PGM spec: one whitespace byte before pixel data */

	if (w <= 0 || h <= 0) {
		fprintf(stderr, "lemdconv: bad PGM dimensions %dx%d in '%s'\n",
		        w, h, path);
		fclose(f);
		return NULL;
	}
	if (maxval != 255) {
		fprintf(stderr,
		        "lemdconv: '%s' has maxval=%d; only 255 is supported\n"
		        "  (convert with: convert input.jpg -depth 8 out.pgm)\n",
		        path, maxval);
		fclose(f);
		return NULL;
	}

	unsigned char *pixels = malloc((size_t)w * (size_t)h);
	if (!pixels) {
		fprintf(stderr, "lemdconv: out of memory for %dx%d source image\n",
		        w, h);
		fclose(f);
		return NULL;
	}

	size_t expected = (size_t)w * (size_t)h;
	size_t got      = fread(pixels, 1, expected, f);
	fclose(f);

	if (got != expected) {
		fprintf(stderr,
		        "lemdconv: short read in '%s' (%zu of %zu bytes)\n",
		        path, got, expected);
		free(pixels);
		return NULL;
	}

	*out_w = w;
	*out_h = h;
	return pixels;
}

/* =========================================================================
 * scale_to_virtual_canvas
 *
 * Scales src (src_w x src_h, 8-bit gray) into a LEMD_W x LEMD_VIRTUAL_H
 * (720x540) canvas using nearest-neighbor sampling, preserving the source
 * aspect ratio.  Unused border areas are zero-filled (black = letterbox
 * bars or pillarbox bars depending on the source aspect ratio).
 *
 * Returns a heap-allocated LEMD_W * LEMD_VIRTUAL_H byte array, or NULL.
 * Caller must free() the returned pointer.
 * ========================================================================= */
static unsigned char *scale_to_virtual_canvas(
	const unsigned char *src, int src_w, int src_h)
{
	/* calloc gives us zero-filled black borders for free. */
	unsigned char *canvas = calloc((size_t)LEMD_W * LEMD_VIRTUAL_H, 1);
	if (!canvas) {
		fprintf(stderr, "lemdconv: out of memory for virtual canvas\n");
		return NULL;
	}

	/*
	 * Choose the scale factor that fits the source entirely within the
	 * canvas without exceeding either dimension.
	 */
	double scale_x = (double)LEMD_W        / (double)src_w;
	double scale_y = (double)LEMD_VIRTUAL_H / (double)src_h;
	double scale   = (scale_x < scale_y) ? scale_x : scale_y;

	int dst_w = (int)(src_w * scale + 0.5);
	int dst_h = (int)(src_h * scale + 0.5);
	if (dst_w > LEMD_W)         dst_w = LEMD_W;
	if (dst_h > LEMD_VIRTUAL_H) dst_h = LEMD_VIRTUAL_H;

	/* Centre the scaled image on the canvas. */
	int off_x = (LEMD_W         - dst_w) / 2;
	int off_y = (LEMD_VIRTUAL_H - dst_h) / 2;

	for (int dy = 0; dy < dst_h; dy++) {
		/* Map destination row to nearest source row. */
		int sy = (int)((dy + 0.5) * src_h / dst_h);
		if (sy >= src_h) sy = src_h - 1;

		for (int dx = 0; dx < dst_w; dx++) {
			int sx = (int)((dx + 0.5) * src_w / dst_w);
			if (sx >= src_w) sx = src_w - 1;

			canvas[(off_y + dy) * LEMD_W + (off_x + dx)] =
				(unsigned char)(255.0 * pow(src[sy * src_w + sx] / 255.0, 0.7) + 0.5);
		}
	}

	return canvas;
}

/* =========================================================================
 * dither_virtual_canvas
 *
 * Applies Floyd-Steinberg error diffusion to the 720x540 8-bit grayscale
 * canvas and returns a bit-packed result: LEMD_STRIDE (90) bytes per row,
 * LEMD_VIRTUAL_H (540) rows, MSB = leftmost pixel.
 *
 * Serpentine scan order reduces horizontal streaking vs. left-to-right only:
 *   Even rows: left -> right
 *   Odd  rows: right -> left  (horizontal error-spread direction mirrors)
 *
 * An int16_t error accumulation buffer is used so that positive and negative
 * error values can accumulate freely without clamping until the threshold
 * comparison.
 *
 * Returns a heap-allocated buffer of LEMD_VIRTUAL_H * LEMD_STRIDE bytes,
 * or NULL on error.  Caller must free().
 * ========================================================================= */
static unsigned char *dither_virtual_canvas(const unsigned char *canvas)
{
	const int rows     = LEMD_VIRTUAL_H;
	const int cols     = LEMD_W;
	const int rowbytes = LEMD_STRIDE;

	int16_t *err = malloc((size_t)rows * cols * sizeof(int16_t));
	if (!err) {
		fprintf(stderr, "lemdconv: out of memory for dither error buffer\n");
		return NULL;
	}
	for (int i = 0; i < rows * cols; i++)
		err[i] = (int16_t)canvas[i];

	unsigned char *out = calloc((size_t)rows * rowbytes, 1);
	if (!out) {
		fprintf(stderr, "lemdconv: out of memory for dither output\n");
		free(err);
		return NULL;
	}

#define CLAMP255(v)  ((v) < 0 ? 0 : (v) > 255 ? 255 : (v))

	for (int y = 0; y < rows; y++) {
		int ltr     = !(y & 1);            /* 1 = left-to-right, 0 = right-to-left */
		int x_start = ltr ? 0      : cols - 1;
		int x_end   = ltr ? cols   : -1;
		int x_step  = ltr ? 1      : -1;
		int r       = x_step;              /* direction of "right neighbour"        */

		for (int x = x_start; x != x_end; x += x_step) {
			int16_t old = (int16_t)CLAMP255(err[y * cols + x]);
			int     bit = (old >= THRESHOLD) ? 1 : 0;
			int16_t qe  = old - (int16_t)(bit ? 255 : 0);  /* quantisation error */

			/* Pack bit into output: bit 7 = leftmost pixel. */
			if (bit)
				out[y * rowbytes + (x >> 3)] |=
					(unsigned char)(0x80 >> (x & 7));

			/*
			 * Distribute error to four neighbours.
			 * In serpentine mode, "right" (r) and "left" (-r) are
			 * screen-relative, so the diffusion pattern always fans
			 * out in the direction of travel plus downward.
			 */
			if (x + r >= 0 && x + r < cols)
				err[y * cols + x + r]       += (int16_t)(qe * 7 / 16);

			if (y + 1 < rows) {
				if (x - r >= 0 && x - r < cols)
					err[(y+1)*cols + x - r] += (int16_t)(qe * 3 / 16);

				err[(y+1)*cols + x]          += (int16_t)(qe * 5 / 16);

				if (x + r >= 0 && x + r < cols)
					err[(y+1)*cols + x + r] += (int16_t)(qe * 1 / 16);
			}
		}
	}

#undef CLAMP255

	free(err);
	return out;
}

/* =========================================================================
 * subsample_to_physical
 *
 * Subsamples the bit-packed 720x540 dithered canvas down to 720x348
 * physical scanlines by mapping each output row y to the nearest-center
 * row in the virtual canvas:
 *
 *   src_row = (int)( (y + 0.5) * LEMD_VIRTUAL_H / LEMD_H )
 *
 * This is where the pixel aspect ratio correction is realised: the 540
 * virtual rows contain a square-pixel image; picking 348 rows from them
 * applies the 540/348 vertical compression that compensates for the
 * display's tall pixels.
 *
 * The dithered data is already bit-packed at 90 bytes/row, so this is
 * a straight row-selection memcpy -- no bit manipulation required.
 *
 * Returns a heap-allocated LEMD_H * LEMD_STRIDE byte array in linear
 * scanline order (scanline 0 first), or NULL on error.  Caller must free().
 * ========================================================================= */
static unsigned char *subsample_to_physical(const unsigned char *dithered)
{
	unsigned char *physical = malloc((size_t)LEMD_H * LEMD_STRIDE);
	if (!physical) {
		fprintf(stderr,
		        "lemdconv: out of memory for physical scanline buffer\n");
		return NULL;
	}

	for (int y = 0; y < LEMD_H; y++) {
		int src_row = (int)((y + 0.5) * LEMD_VIRTUAL_H / LEMD_H);
		if (src_row >= LEMD_VIRTUAL_H) src_row = LEMD_VIRTUAL_H - 1;

		memcpy(physical + (size_t)y       * LEMD_STRIDE,
		       dithered  + (size_t)src_row * LEMD_STRIDE,
		       LEMD_STRIDE);
	}

	return physical;
}

/* =========================================================================
 * interleave
 *
 * Scatters linear scanlines into the LEMD 4-bank interleave layout:
 *
 *   bank = scanline & 3
 *   row  = scanline >> 2
 *   file_offset = bank * LEMD_BANK_BYTES + row * LEMD_STRIDE
 *
 * The resulting buffer can be written directly to disk and later loaded
 * bank-by-bank into the LEMD framebuffer with four REP MOVSB operations.
 *
 * Returns a heap-allocated LEMD_TOTAL_BYTES (31320) buffer, or NULL.
 * Caller must free().
 * ========================================================================= */
static unsigned char *interleave(const unsigned char *physical)
{
	unsigned char *out = malloc(LEMD_TOTAL_BYTES);
	if (!out) {
		fprintf(stderr, "lemdconv: out of memory for interleave buffer\n");
		return NULL;
	}

	for (int y = 0; y < LEMD_H; y++) {
		int    bank    = y & 3;
		int    row     = y >> 2;
		size_t dst_off = (size_t)bank * LEMD_BANK_BYTES
		               + (size_t)row  * LEMD_STRIDE;
		memcpy(out + dst_off,
		       physical + (size_t)y * LEMD_STRIDE,
		       LEMD_STRIDE);
	}

	return out;
}

/* =========================================================================
 * main
 * ========================================================================= */
int main(int argc, char *argv[])
{
	if (argc != 3) {
		fprintf(stderr,
		        "Usage: lemdconv input.pgm output.lemd\n"
		        "\n"
		        "Converts a grayscale PGM image to the Leading Edge Model D\n"
		        "enhanced monochrome framebuffer format (720x348, 4-bank interleave).\n"
		        "\n"
		        "Prepare input with ImageMagick:\n"
		        "  convert photo.jpg -resize 720x540^ -gravity center \\\n"
		        "          -extent 720x540 -colorspace Gray input.pgm\n");
		return 1;
	}

	const char *in_path  = argv[1];
	const char *out_path = argv[2];
	unsigned char *buf;
	int src_w, src_h;

	/* 1. Read source PGM. */
	buf = pgm_read(in_path, &src_w, &src_h);
	if (!buf) return 1;
	fprintf(stderr, "lemdconv: read %dx%d source image\n", src_w, src_h);

	/* 2. Scale into 720x540 virtual canvas with letterbox/pillarbox. */
	unsigned char *canvas = scale_to_virtual_canvas(buf, src_w, src_h);
	free(buf);
	if (!canvas) return 1;
	fprintf(stderr, "lemdconv: scaled to %dx%d virtual canvas\n",
	        LEMD_W, LEMD_VIRTUAL_H);

	/* 3. Floyd-Steinberg dither to 1-bit (serpentine scan order). */
	unsigned char *dithered = dither_virtual_canvas(canvas);
	free(canvas);
	if (!dithered) return 1;
	fprintf(stderr, "lemdconv: dithered to 1-bit\n");

	/* 4. Subsample 540 virtual rows -> 348 physical scanlines.
	 *    This step applies the pixel aspect ratio correction. */
	unsigned char *physical = subsample_to_physical(dithered);
	free(dithered);
	if (!physical) return 1;
	fprintf(stderr, "lemdconv: subsampled to %d physical scanlines\n", LEMD_H);

	/* 5. Scatter into LEMD 4-bank interleave order. */
	unsigned char *lemd = interleave(physical);
	free(physical);
	if (!lemd) return 1;
	fprintf(stderr, "lemdconv: interleaved into LEMD bank layout\n");

	/* 6. Write output file. */
	FILE *f = fopen(out_path, "wb");
	if (!f) {
		fprintf(stderr, "lemdconv: cannot open '%s' for writing: %s\n",
		        out_path, strerror(errno));
		free(lemd);
		return 1;
	}

	size_t written = fwrite(lemd, 1, LEMD_TOTAL_BYTES, f);
	fclose(f);
	free(lemd);

	if (written != LEMD_TOTAL_BYTES) {
		fprintf(stderr, "lemdconv: short write (%zu of %d bytes)\n",
		        written, LEMD_TOTAL_BYTES);
		return 1;
	}

	fprintf(stderr, "lemdconv: wrote %d bytes to '%s'\n",
	        LEMD_TOTAL_BYTES, out_path);
	return 0;
}
