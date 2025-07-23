.PHONY: $(SUBMODULES) install clean

# Submodules to manage
SUBMODULES := neovim nnn fzf vim

# Local binary directory
LOCALBIN := $(HOME)/.local/bin

# Per-submodule build and install flags
NEOVIM_MAKE_FLAGS := CMAKE_BUILD_TYPE=RelWithDebInfo CMAKE_INSTALL_PREFIX=$(LOCALBIN)
NEOVIM_INSTALL_FLAGS :=

NEOVIM_MAKE_FLAGS := -j$(shell nproc) CMAKE_BUILD_TYPE=RelWithDebInfo CMAKE_INSTALL_PREFIX=$(HOME)/.local
NEOVIM_INSTALL_FLAGS := -DCMAKE_INSTALL_PREFIX=$(HOME)/.local -DCMAKE_INSTALL_MANDIR=$(HOME)/.local/share/man

FZF_MAKE_FLAGS := --bin
FZF_INSTALL_FLAGS := && cp bin/fzf $(LOCALBIN)

VIM_MAKE_FLAGS :=
VIM_INSTALL_FLAGS :=

# Define build/install/clean rules using submodule name and uppercase key
define build_template
$1:
	$(MAKE) -C $1 $(strip $$($2_MAKE_FLAGS))

$1-install:
	$(MAKE) -C $1 install $(strip $$($2_INSTALL_FLAGS))

$1-clean:
	$(MAKE) -C $1 clean
endef

# Generate targets
$(eval $(call build_template,neovim,NEOVIM))
$(eval $(call build_template,nnn,NNN))
$(eval $(call build_template,fzf,FZF))
$(eval $(call build_template,vim,VIM))

# Aggregate targets
install: $(addsuffix -install,$(SUBMODULES))
clean: $(addsuffix -clean,$(SUBMODULES))
