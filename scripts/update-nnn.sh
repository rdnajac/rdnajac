#!/bin/bash
# updates nnn
set -eux

cd "$(dirname "${BASH_SOURCE[0]}")" || exit
cd ../nnn && make clean && make && cp nnn ~/.local/bin
