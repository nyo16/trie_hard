#!/usr/bin/env bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

REPO="nyo16/trie_hard"

# Function to get current version from mix.exs
get_current_version() {
    awk -F'"' '/^  @version / { print $2; exit }' mix.exs
}

# Function to update version in mix.exs, Cargo.toml and Cargo.lock
update_version() {
    local new_version=$1
    sed -i.bak "s/@version \".*\"/@version \"$new_version\"/" mix.exs
    rm mix.exs.bak

    # Bump the first `version = ` line (the [package] section) in Cargo.toml
    local cargo_toml="native/trie_hard_native/Cargo.toml"
    awk -v v="$new_version" '!done && /^version = / { print "version = \"" v "\""; done = 1; next } { print }' \
        "$cargo_toml" > "$cargo_toml.tmp"
    mv "$cargo_toml.tmp" "$cargo_toml"

    # Record the new crate version in Cargo.lock (release builds use --locked).
    (cd native/trie_hard_native && cargo update --workspace --offline)
}

# Function to validate version format
validate_version() {
    local version=$1
    if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?$ ]]; then
        print_error "Invalid version format. Use semver format (e.g., 1.0.0, 1.0.0-beta)"
        exit 1
    fi
}

# Function to check if tag already exists
check_tag_exists() {
    local tag=$1
    if git rev-parse -q --verify "refs/tags/$tag" > /dev/null; then
        print_error "Tag $tag already exists locally!"
        exit 1
    fi
    if [[ -n "$(git ls-remote --tags origin "refs/tags/$tag")" ]]; then
        print_error "Tag $tag already exists on origin!"
        exit 1
    fi
}

# Releases are cut from an up-to-date master, before anything is committed.
check_release_branch() {
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD)
    if [[ "$current_branch" != "master" ]]; then
        print_error "Releases must be cut from master (current branch: $current_branch)."
        exit 1
    fi
    git fetch origin master
    if [[ "$(git rev-parse master)" != "$(git rev-parse origin/master)" ]]; then
        print_error "Local master differs from origin/master. Pull or push first."
        exit 1
    fi
}

# What gets published must be exactly the tagged commit: no local edits and no
# untracked files (mix hex.publish packs the working tree).
check_tree_matches_tag() {
    local tag=$1
    if ! git rev-parse -q --verify "refs/tags/$tag^{commit}" > /dev/null; then
        print_error "Tag $tag does not exist locally. Run 'git fetch --tags' first."
        exit 1
    fi
    if [[ "$(git rev-parse HEAD)" != "$(git rev-parse "$tag^{commit}")" ]]; then
        print_error "HEAD is not the commit tagged $tag. Check out $tag first."
        exit 1
    fi
    if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
        print_error "Working tree is not clean (including untracked files):"
        git status --porcelain --untracked-files=all
        exit 1
    fi
}

# Function to check git status
check_git_status() {
    if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
        print_error "You have uncommitted or untracked changes. Please commit or stash them first."
        git status --porcelain --untracked-files=all
        exit 1
    fi
}

# Function to run tests
run_tests() {
    print_info "Running tests..."
    if ! TRIE_HARD_BUILD=1 mix test; then
        print_error "Tests failed! Aborting release."
        exit 1
    fi
    print_success "Tests passed!"
}

# Function to check formatting
check_formatting() {
    print_info "Checking Elixir formatting..."
    if ! mix format --check-formatted; then
        print_error "Code is not formatted. Run 'mix format' first."
        exit 1
    fi

    print_info "Checking Rust formatting..."
    if ! (cd native/trie_hard_native && cargo fmt -- --check); then
        print_error "Rust code is not formatted. Run 'cargo fmt' first."
        exit 1
    fi

    print_success "All code is properly formatted!"
}

# Function to create and push tag
create_and_push_tag() {
    local version=$1
    local tag="v$version"

    print_info "Creating tag $tag..."
    git tag -a "$tag" -m "Release $tag"

    print_info "Pushing tag to origin..."
    git push origin "$tag"

    print_success "Tag $tag created and pushed!"
}

# Function to wait for GitHub Actions to complete
wait_for_actions() {
    local tag=$1
    print_info "Waiting for GitHub Actions to complete building NIFs for $tag..."
    print_info "You can monitor progress at: https://github.com/nyo16/trie_hard/actions"

    print_warning "Press ENTER when all GitHub Actions workflows have completed successfully..."
    read -r
}

# Function to generate checksum file
sha256_of() {
    if command -v sha256sum > /dev/null; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# Generates the checksum file and proves it covers exactly the attested
# artifacts: every asset is verified against the tagged release workflow, and
# every checksum entry must equal the SHA-256 of a verified asset.
generate_checksum() {
    local version=$1
    local tag="v$version"
    local assets_dir
    assets_dir=$(mktemp -d)
    trap 'rm -rf "$assets_dir"' RETURN

    print_info "Downloading release assets for $tag..."
    if ! gh release download "$tag" --repo "$REPO" --dir "$assets_dir" --pattern '*.tar.gz'; then
        print_error "Failed to download release assets for $tag."
        exit 1
    fi

    print_info "Verifying build provenance attestations..."
    local asset count=0
    for asset in "$assets_dir"/*.tar.gz; do
        [[ -e "$asset" ]] || continue
        count=$((count + 1))
        if ! gh attestation verify "$asset" \
            --repo "$REPO" \
            --signer-workflow "$REPO/.github/workflows/release.yml" \
            --source-ref "refs/tags/$tag" \
            --deny-self-hosted-runners; then
            print_error "Attestation verification failed for $(basename "$asset"). Aborting."
            exit 1
        fi
    done
    if [[ "$count" -eq 0 ]]; then
        print_error "No release assets found for $tag."
        exit 1
    fi
    print_success "$count release assets have valid attestations from the $tag release workflow."

    print_info "Generating checksum file for precompiled NIFs..."
    if ! mix rustler_precompiled.download TrieHard.Native --all --print; then
        print_error "Failed to download precompiled NIFs or generate checksum."
        print_info "Make sure all GitHub Actions builds completed successfully."
        exit 1
    fi

    local checksum_file
    checksum_file=$(ls checksum-*.exs 2> /dev/null || true)
    if [[ -z "$checksum_file" ]]; then
        print_error "No checksum file found. This is required for publishing to Hex."
        exit 1
    fi

    # Each entry looks like: "<file>.tar.gz" => "sha256:<hex>",
    local entries
    entries=$(grep -c '=> "sha256:' "$checksum_file" || true)
    if [[ "$entries" -ne "$count" ]]; then
        print_error "$checksum_file has $entries entries but $count attested assets were verified."
        exit 1
    fi
    for asset in "$assets_dir"/*.tar.gz; do
        local name expected
        name=$(basename "$asset")
        expected="\"$name\" => \"sha256:$(sha256_of "$asset")\""
        if ! grep -qF -- "$expected" "$checksum_file"; then
            print_error "$checksum_file does not match the attested bytes of $name."
            exit 1
        fi
    done
    print_success "Checksum file $checksum_file matches all $count attested assets."
    print_warning "Commit $checksum_file after publishing (it is tracked in git)."
}

# Function to verify package contents
verify_package() {
    print_info "Verifying package contents..."

    # Build package and show contents
    mix hex.build --unpack

    print_info "Package contents:"
    ls -la trie_hard-*/ || true

    print_warning "Please verify the package contains all necessary files. Press ENTER to continue..."
    read -r
}

# Function to publish to Hex
publish_to_hex() {
    local version=$1

    print_info "Publishing version $version to Hex.pm..."
    print_warning "This will publish the package publicly. Are you sure? (y/N)"
    read -r confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "Publish cancelled."
        exit 0
    fi

    if ! mix hex.publish; then
        print_error "Failed to publish to Hex. Check the output above for errors."
        exit 1
    fi

    print_success "Successfully published $version to Hex.pm!"
    print_info "Package URL: https://hex.pm/packages/trie_hard"
}

# Function to cleanup
cleanup() {
    print_info "Cleaning up temporary files..."
    rm -rf trie_hard-*/ || true
    print_success "Cleanup completed!"
}

# Function to show help
show_help() {
    cat << EOF
Usage: $0 [OPTIONS] <version>

Complete release workflow for rustler_precompiled packages to Hex.pm

OPTIONS:
    -h, --help          Show this help message
    -s, --skip-tests    Skip running tests
    -f, --skip-format   Skip formatting checks
    --tag-only          Only create and push git tag (skip Hex publishing)
    --hex-only          Only do Hex publishing steps (assumes tag exists)
    --dry-run           Show what would be done without actually doing it

EXAMPLES:
    $0 1.0.0                    # Complete release workflow
    $0 --tag-only 1.0.1         # Only create git tag and trigger builds
    $0 --hex-only 1.0.1         # Only do checksum + Hex publishing
    $0 --skip-tests 1.0.2       # Release without running tests
    $0 --dry-run 1.0.3          # Show what would happen

COMPLETE WORKFLOW:
    1. Check branch is an up-to-date master and the tree is clean (incl. untracked)
    2. Validate version format
    3. Check if tag already exists (locally and on origin)
    4. Run tests (unless --skip-tests)
    5. Check code formatting (unless --skip-format)
    6. Update version in mix.exs, Cargo.toml and Cargo.lock
    7. Commit version change
    8. Create and push git tag
    9. Wait for GitHub Actions to build all NIFs
    10. Check HEAD is the tagged commit with a clean tree (also for --hex-only)
    11. Verify attestations (release workflow, tag ref, GitHub-hosted runners),
        generate the checksum file and check it matches the attested bytes
    12. Verify package contents
    13. Publish to Hex.pm

The rustler_precompiled flow requires:
- GitHub Actions to build NIFs for multiple platforms
- Checksum file generation from precompiled artifacts
- Hex package with both source code and checksum

EOF
}

# Parse command line arguments
SKIP_TESTS=false
SKIP_FORMAT=false
DRY_RUN=false
TAG_ONLY=false
HEX_ONLY=false
VERSION=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -s|--skip-tests)
            SKIP_TESTS=true
            shift
            ;;
        -f|--skip-format)
            SKIP_FORMAT=true
            shift
            ;;
        --tag-only)
            TAG_ONLY=true
            shift
            ;;
        --hex-only)
            HEX_ONLY=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -*)
            print_error "Unknown option $1"
            show_help
            exit 1
            ;;
        *)
            if [[ -z "$VERSION" ]]; then
                VERSION=$1
            else
                print_error "Multiple versions specified"
                show_help
                exit 1
            fi
            shift
            ;;
    esac
done

# Check if version was provided
if [[ -z "$VERSION" ]]; then
    print_error "Version is required"
    show_help
    exit 1
fi

# Main execution
print_info "Starting release process for version $VERSION"

current_version=$(get_current_version)
print_info "Current version: $current_version"

if [[ "$DRY_RUN" == "true" ]]; then
    print_warning "DRY RUN MODE - No changes will be made"
fi

# Validation steps
validate_version "$VERSION"

if [[ "$HEX_ONLY" == "false" ]]; then
    git fetch --tags
    check_tag_exists "v$VERSION"

    if [[ "$DRY_RUN" == "false" ]]; then
        check_release_branch
        check_git_status
    fi
fi

# Run pre-release checks
if [[ "$HEX_ONLY" == "false" ]]; then
    if [[ "$SKIP_FORMAT" == "false" ]]; then
        if [[ "$DRY_RUN" == "false" ]]; then
            check_formatting
        else
            print_info "Would check code formatting"
        fi
    fi

    if [[ "$SKIP_TESTS" == "false" ]]; then
        if [[ "$DRY_RUN" == "false" ]]; then
            run_tests
        else
            print_info "Would run tests"
        fi
    fi
fi

# Version update and tagging
if [[ "$HEX_ONLY" == "false" ]]; then
    if [[ "$DRY_RUN" == "false" ]]; then
        print_info "Updating version to $VERSION..."
        update_version "$VERSION"

        print_info "Committing version change..."
        git add mix.exs native/trie_hard_native/Cargo.toml native/trie_hard_native/Cargo.lock
        git commit -m "Bump version to $VERSION"

        print_info "Pushing version change..."
        git push origin master

        create_and_push_tag "$VERSION"

        if [[ "$TAG_ONLY" == "false" ]]; then
            wait_for_actions "v$VERSION"
        else
            print_success "Tag v$VERSION created! GitHub Actions will build precompiled NIFs."
            print_info "Use '$0 --hex-only $VERSION' after builds complete to publish to Hex."
            exit 0
        fi
    else
        print_info "Would update version to $VERSION"
        print_info "Would commit and push changes"
        print_info "Would create and push tag v$VERSION"
        print_info "Would wait for GitHub Actions to complete"
    fi
fi

# Hex publishing workflow
if [[ "$TAG_ONLY" == "false" ]]; then
    if [[ "$DRY_RUN" == "false" ]]; then
        check_tree_matches_tag "v$VERSION"
        generate_checksum "$VERSION"
        verify_package
        publish_to_hex "$VERSION"
        cleanup

        print_success "Release $VERSION completed successfully!"
        print_info "Package is now available at: https://hex.pm/packages/trie_hard"
    else
        print_info "Would check HEAD is v$VERSION with a clean tree"
        print_info "Would verify attestations and generate a matching checksum file"
        print_info "Would verify package contents"
        print_info "Would publish to Hex.pm"
        print_info "Would cleanup temporary files"
    fi
fi