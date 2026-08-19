PREFIX ?= /usr/local

slidedial: slidedial.swift
	swiftc -O -o slidedial slidedial.swift

install: slidedial
	install -m 755 slidedial $(PREFIX)/bin/slidedial

uninstall:
	rm -f $(PREFIX)/bin/slidedial

clean:
	rm -f slidedial

.PHONY: install uninstall clean
