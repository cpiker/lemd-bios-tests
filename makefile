# Build the bios tests


DEST=concorde:/disk/1/dos/mount/gibbeon_c/test

PROGS=lemdmon2.com monospd1.com lemdshow.com lemdconv lemdrtim.com bdainfo.com

BUILD=$(patsubst %, build/%, $(PROGS))

build/%.com:src/%.asm
	nasm -f bin -o $@ $<

build/%:src/%.c
	gcc -O2 -Wall -o $@ -lm $<

all: $(BUILD)


install:
	scp $(BUILD) $(DEST)
