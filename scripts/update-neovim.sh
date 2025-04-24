#!/bin/bash
# updates neovim
set -eux

cd "$(dirname "${BASH_SOURCE[0]}")" || exit
cd ../neovim \
	&& make CMAKE_BUILD_TYPE=RelWithDebInfo CMAKE_INSTALL_PREFIX=~/.local/bin \
	&& make install
