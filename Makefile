CC      ?= clang
CFLAGS  ?= -O2 -Wall -Wextra -Wno-unused-parameter
KIT     := -framework IOKit -framework CoreFoundation

all: kext turbod clocktest

# Our kernel extension. Builds with the Command Line Tools alone.
kext:
	sh ./kext/build.sh

turbod: turbod.c
	$(CC) $(CFLAGS) -o $@ $< $(KIT)

clocktest: clocktest.c
	$(CC) $(CFLAGS) -o $@ $<

# Sandboxed end-to-end test of the daemon protocol. No root, no kext writes.
check: clocktest
	sh ./test-sandbox.sh

status: clocktest
	./turboctl status

doctor: clocktest
	./turboctl doctor

# install/uninstall/package: the scripts check for root and say so.
install: all
	./install.sh

uninstall:
	./uninstall.sh

package:
	./packaging/build-package.sh

clean:
	rm -f turbod clocktest
	rm -rf kext/TurboLock.kext

distclean: clean
	rm -rf .build dist

.PHONY: all kext check status doctor install uninstall package clean distclean
