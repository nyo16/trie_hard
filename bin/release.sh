#!/bin/bash

set -e

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
    if git tag -l | grep -q "^$tag$"; then
        print_error "Tag $tag already exists!"
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
    if ! cd native/trie_hard_native && cargo fmt -- --check; then
        print_error "Rust code is not formatted. Run 'cargo fmt' first."
        exit 1
    fi
    cd ../..

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

# Function to show help
show_help() {
    cat << EOF
Usage: $0 [OPTIONS] <version>

Create a new release by updating version, running tests, and creating a git tag.

OPTIONS:
    -h, --help          Show this help message
    -s, --skip-tests    Skip running tests
    -f, --skip-format   Skip formatting checks
    --dry-run           Show what would be done without actually doing it

EXAMPLES:
    $0 1.0.0                    # Create release v1.0.0
    $0 1.0.1-beta               # Create pre-release v1.0.1-beta
    $0 --skip-tests 1.0.2       # Create release without running tests
    $0 --dry-run 1.0.3          # Show what would happen

WORKFLOW:
    1. Check git status (no uncommitted changes)
    2. Validate version format
    3. Check if tag already exists
    4. Run tests (unless --skip-tests)
    5. Check code formatting (unless --skip-format)
    6. Update version in mix.exs
    7. Commit version change
    8. Create and push git tag
    9. GitHub Actions will automatically build and release precompiled binaries

EOF
}

# Parse command line arguments
SKIP_TESTS=false
SKIP_FORMAT=false
DRY_RUN=false
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
check_tag_exists "v$VERSION"

if [[ "$DRY_RUN" == "false" ]]; then
    check_git_status
fi

# Run tests and checks
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

# Update version and create release
if [[ "$DRY_RUN" == "false" ]]; then
    print_info "Updating version to $VERSION..."
    update_version "$VERSION"

    print_info "Committing version change..."
    git add mix.exs
    git commit -m "Bump version to $VERSION"

    print_info "Pushing version change..."
    git push origin master

    create_and_push_tag "$VERSION"

    print_success "Release $VERSION created successfully!"
    print_info "GitHub Actions will now build precompiled binaries and create the GitHub release."
    print_info "Check the Actions tab at: https://github.com/nyo16/trie_hard/actions"
else
    print_info "Would update version to $VERSION"
    print_info "Would commit and push changes"
    print_info "Would create and push tag v$VERSION"
    print_info "GitHub Actions would build precompiled binaries"
fi