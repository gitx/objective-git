# Common objective-git developer commands. Run `make help` for the list.
#
# Targets deliberately mirror the steps in .github/workflows/BuildPR.yml so the
# two stay in sync; the CI step each one matches is named below.
# Changing a command here means changing it there too, and the other way round.
#
#   deps      "script/bootstrap" and "script/update_libgit2"
#   test      "Test project" (commented out in CI for now)
#   archive   "Archive project"
#
# Override the architecture on an Intel Mac or for a cross build:
#   make build ARCH=x86_64

ARCH ?= $(shell uname -m)

WORKSPACE := ObjectiveGitFramework.xcworkspace
SCHEME := ObjectiveGit Mac
DESTINATION := platform=macOS,arch=$(ARCH)

LIBGIT2_ARCHIVE := External/libgit2.a
LIBGIT2_BUILD_DIR := External/libgit2/build

XCODEBUILD := xcodebuild -workspace $(WORKSPACE) -scheme "$(SCHEME)" ARCHS="$(ARCH)"

MAKEFILE := $(firstword $(MAKEFILE_LIST))

# Column the map target lines its descriptions up in.
MAP_WIDTH := 24

.PHONY: help map git-submodule-sync git-submodule-check deps bootstrap \
	libgit2-clean build test archive clean git-clean-dry-run

help: ## Show this help
	@grep -hE '^[A-Za-z][A-Za-z0-9_.-]*:.*## ' $(MAKEFILE_LIST) \
		| awk -F':.*## ' '{printf "  %-20s %s\n", $$1, $$2}'

# Reads the edges out of make's own rule database, so a target that gains a
# prerequisite appears here without anyone maintaining a second copy of the
# graph. The descriptions alongside are the help text above, in a column.
map: ## Show which targets pull in which, with the help text
	@{ make -pnr -f $(MAKEFILE) 2>/dev/null \
	   | sed -n 's/^\([a-zA-Z][A-Za-z0-9_.-]*\):\([^=]*\)$$/EDGE \1\2/p' \
	   | grep -v '^EDGE $(MAKEFILE)' | sort -u; \
	   sed -n 's/^\([a-zA-Z][A-Za-z0-9_.-]*\):.*## \(.*\)$$/DESC \1 \2/p' $(MAKEFILE_LIST); } \
	| awk -v width=$(MAP_WIDTH) '$$1 == "EDGE" { target = $$2; $$1 = ""; $$2 = ""; sub(/^ +/, ""); prerequisites[target] = $$0; order[++found] = target; next } \
	       $$1 == "DESC" { target = $$2; $$1 = ""; $$2 = ""; sub(/^ +/, ""); description[target] = $$0; next } \
	       function label(indent, name,   left) { \
	           left = indent name; \
	           return (name in description ? sprintf("%-" width "s - %s", left, description[name]) : left) \
	       } \
	       function walk(name, indent,   i, count, needs) { \
	           count = split(prerequisites[name], needs, " "); \
	           for (i = 1; i <= count; i++) { print label(indent "\\_ ", needs[i]); walk(needs[i], indent "   ") } \
	       } \
	       END { \
	           if (found == 0) exit 1; \
	           print "Make Targets Map _______________________________________________________________"; print ""; \
	           print "Targets that pull something in _________"; print ""; \
	           for (i = 1; i <= found; i++) if (prerequisites[order[i]] != "") { print label("", order[i]); walk(order[i], ""); print "" } \
	           print "Targets that stand alone _______________"; print ""; \
	           for (i = 1; i <= found; i++) if (prerequisites[order[i]] == "") print label("", order[i]) \
	       }' \
	|| { echo "map: no targets found in $(MAKEFILE)" >&2; exit 1; }

git-submodule-sync: ## Check out the submodules at the revisions this tree wants
	git submodule sync --recursive
	git submodule update --init --recursive

# Locally this warns and carries on, since parking a submodule on a commit of
# your own is a normal thing to be doing. On CI the checkout step is the only
# thing that puts submodules in place, so there drift fails the build.
#
# GitHub reads its annotations from stdout, and %0A is how one carries a
# newline.
git-submodule-check: ## Report a submodule that is not at the revision this tree wants
	@drifted=$$(git submodule status --recursive 2>/dev/null | grep '^[+-]'); \
	test -n "$$drifted" || exit 0; \
	list=$$(echo "$$drifted" | awk '/^-/ { print $$2 " is not checked out"; next } \
		{ print $$2 " is at " substr($$1, 2, 8) }'); \
	if [ -n "$$GITHUB_ACTIONS" ]; then \
		summary="the checkout left submodules that are not at the recorded revisions"; \
		echo "::error title=Submodule drift::$$(printf '%s\n%s\n' "$$summary" "$$list" \
			| awk '{ printf "%s%s", separator, $$0; separator = "%0A" }')"; \
		{ echo "error: $$summary:"; echo "$$list" | sed 's/^/  /'; } >&2; \
		exit 1; \
	fi; \
	{ echo "warning: submodules are not at the revisions this tree wants:"; \
	  echo "$$list" | sed 's/^/  /'; \
	  echo 'run `make git-submodule-sync` to check them out'; } >&2

deps: ## Install the Homebrew tools and build libgit2
	script/bootstrap
	script/update_libgit2

bootstrap: deps ## (alias)

libgit2-clean: ## Drop the built libgit2 so the next deps or build rebuilds it
	rm -rf $(LIBGIT2_ARCHIVE) $(LIBGIT2_ARCHIVE).stamp $(LIBGIT2_BUILD_DIR)

build: git-submodule-check ## Build the macOS framework
	$(XCODEBUILD) -destination "$(DESTINATION)" build

test: git-submodule-check ## Run the macOS framework specs
	$(XCODEBUILD) -destination "$(DESTINATION)" test

archive: git-submodule-check ## Build a release archive of the macOS framework
	$(XCODEBUILD) archive

clean: ## Remove the libgit2 build and Xcode's build products
	$(MAKE) --no-print-directory libgit2-clean
	$(XCODEBUILD) clean

# Lists only, and nothing depends on it: the real `git clean -Xdf` throws away
# every ignored file in the tree, not just the ones a build made, so deciding
# to run it is left to you.
git-clean-dry-run: ## List the ignored files a `git clean -Xdf` would remove
	git clean -Xdn
