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

# Function to get current version from mix.exs
get_current_version() {
    grep '@version' mix.exs | head -n 1 | sed 's/.*@version "\(.*\)".*/\1/'
}

# Function to update version in mix.exs
update_version() {
    local new_version=$1
    sed -i.bak "s/@version \".*\"/@version \"$new_version\"/" mix.exs
    rm mix.exs.bak

    # Bump the first `version = ` line (the [package] section) in Cargo.toml
    local cargo_toml="native/trie_hard_native/Cargo.toml"
    awk -v v="$new_version" '!done && /^version = / { print "version = \"" v "\""; done = 1; next } { print }' \
        "$cargo_toml" > "$cargo_toml.tmp"
    mv "$cargo_toml.tmp" "$cargo_toml"
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
    if git tag -l | grep -qx -- "$tag"; then
        print_error "Tag $tag already exists locally!"
        exit 1
    fi
    if [[ -n "$(git ls-remote --tags origin "refs/tags/$tag")" ]]; then
        print_error "Tag $tag already exists on origin!"
        exit 1
    fi
}

# Function to check git status
check_git_status() {
    if ! git diff-index --quiet HEAD --; then
        print_error "You have uncommitted changes. Please commit or stash them first."
        git status --porcelain
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
generate_checksum() {
    local version=$1
    print_info "Verifying build provenance attestations for release v$version..."
    local assets_dir
    assets_dir=$(mktemp -d)
    if ! gh release download "v$version" --repo nyo16/trie_hard --dir "$assets_dir" --pattern '*.tar.gz'; then
        print_error "Failed to download release assets for v$version."
        rm -rf "$assets_dir"
        exit 1
    fi
    local asset found=false
    for asset in "$assets_dir"/*.tar.gz; do
        [[ -e "$asset" ]] || continue
        found=true
        if ! gh attestation verify "$asset" --repo nyo16/trie_hard; then
            print_error "Attestation verification failed for $(basename "$asset"). Aborting."
            rm -rf "$assets_dir"
            exit 1
        fi
    done
    rm -rf "$assets_dir"
    if [[ "$found" == "false" ]]; then
        print_error "No release assets found for v$version."
        exit 1
    fi
    print_success "All release assets have valid attestations!"

    print_info "Generating checksum file for precompiled NIFs..."

    # Download all precompiled NIFs and generate checksum
    if ! timeout 60 mix rustler_precompiled.download TrieHard.Native --all --print; then
        print_error "Failed to download precompiled NIFs or generate checksum."
        print_info "Make sure all GitHub Actions builds completed successfully."
        exit 1
    fi

    # Check if checksum file was created
    if ls checksum-*.exs 1> /dev/null 2>&1; then
        local checksum_file
        checksum_file=$(ls checksum-*.exs)
        print_success "Checksum file created: $checksum_file"
    else
        print_error "No checksum file found. This is required for publishing to Hex."
        exit 1
    fi
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
    1. Check git status (no uncommitted changes)
    2. Validate version format
    3. Check if tag already exists
    4. Run tests (unless --skip-tests)
    5. Check code formatting (unless --skip-format)
    6. Update version in mix.exs and native/trie_hard_native/Cargo.toml
    7. Commit version change
    8. Create and push git tag
    9. Wait for GitHub Actions to build all NIFs
    10. Verify artifact attestations, generate checksum file from precompiled NIFs
    11. Verify package contents
    12. Publish to Hex.pm

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
        git add mix.exs native/trie_hard_native/Cargo.toml
        if ! git diff --quiet -- native/trie_hard_native/Cargo.lock; then
            git add native/trie_hard_native/Cargo.lock
        fi
        git commit -m "Bump version to $VERSION"

        current_branch=$(git rev-parse --abbrev-ref HEAD)
        if [[ "$current_branch" != "master" ]]; then
            print_error "Releases must be pushed from master (current branch: $current_branch)."
            exit 1
        fi

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
        generate_checksum "$VERSION"
        verify_package
        publish_to_hex "$VERSION"
        cleanup

        print_success "Release $VERSION completed successfully!"
        print_info "Package is now available at: https://hex.pm/packages/trie_hard"
    else
        print_info "Would generate checksum file"
        print_info "Would verify package contents"
        print_info "Would publish to Hex.pm"
        print_info "Would cleanup temporary files"
    fi
fi