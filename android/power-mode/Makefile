android_dir := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)

.PHONY: format check build install

format:
	bash $(android_dir)/format-power-mode.sh

check:
	bash $(android_dir)/check-power-mode.sh

build:
	bash $(android_dir)/build-power-mode.sh

install:
	bash $(android_dir)/install-power-mode.sh $(SERIAL)
