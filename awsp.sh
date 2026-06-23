#!/usr/bin/env bash
 
# We wrap the core logic in a function to avoid polluting the user's shell with local variables when sourced.
_awsp_main() {
    local CONFIG_FILE="${HOME}/.aws/config"
    local profiles=()
    local line
    local profile
    local credentials
    local response
    local PS3="Choose a profile number: "

    # Detect if the script is sourced or run directly
    local is_sourced=false
    if [[ -n "$BASH_VERSION" ]]; then
        if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
            is_sourced=true
        fi
    elif [[ -n "$ZSH_VERSION" ]]; then
        if [[ "$ZSH_EVAL_CONTEXT" == *file* ]]; then
            is_sourced=true
        fi
    fi

    if [[ "$is_sourced" = false ]]; then
        echo "Error: This script must be sourced to set environment variables in your current shell."
        echo "Please run:"
        echo "    source /Users/macbook/Projekt/mac/kubernetes/awsp.sh"
        echo "or:"
        echo "    . /Users/macbook/Projekt/mac/kubernetes/awsp.sh"
        exit 1
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "AWS config file not found: $CONFIG_FILE"
        return 1 2>/dev/null || exit 1
    fi

    # Read profiles into an array. Works in both Bash (including old macOS v3.2) and Zsh.
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            profiles+=("$line")
        fi
    done < <(
        grep '^\[profile ' "$CONFIG_FILE" \
        | sed -E 's/^\[profile (.*)\]$/\1/' \
        | sort
    )

    if [[ ${#profiles[@]} -eq 0 ]]; then
        echo "No AWS profiles found in $CONFIG_FILE"
        return 1 2>/dev/null || exit 1
    fi

    # Add a Cancel option to the menu
    profiles+=("Cancel")

    echo
    echo "Available AWS profiles:"
    echo

    # Prompt user to select a profile
    select profile in "${profiles[@]}"; do
        if [[ "$profile" == "Cancel" ]]; then
            echo "Cancelled."
            return 0 2>/dev/null || exit 0
        elif [[ -n "${profile:-}" ]]; then
            break
        fi
        echo "Invalid selection. Please choose a valid number."
    done

    echo
    echo "Selected profile: $profile"
    echo

    # Unset existing AWS environment variables to prevent conflicts
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION AWS_PROFILE

    # Obtain credentials
    credentials=$(aws configure export-credentials --profile "$profile" --format env 2>/dev/null)
    if [[ $? -ne 0 ]] || [[ -z "$credentials" ]]; then
        echo "Error: Failed to retrieve credentials for profile '$profile'."
        
        # Check if it is an SSO profile and offer login if needed
        if grep -A 10 "\[profile \"\?$profile\"\?\]" "$CONFIG_FILE" 2>/dev/null | grep -E -q "sso_start_url|sso_session"; then
            echo "This profile appears to use AWS SSO. Your session might be expired."
            if [[ -n "$ZSH_VERSION" ]]; then
                read -r "response?Would you like to run 'aws sso login --profile $profile'? [y/N] "
            else
                read -r -p "Would you like to run 'aws sso login --profile $profile'? [y/N] " response
            fi
            if [[ "$response" =~ ^[yY](es)?$ ]]; then
                aws sso login --profile "$profile"
                credentials=$(aws configure export-credentials --profile "$profile" --format env 2>/dev/null)
                if [[ $? -ne 0 ]] || [[ -z "$credentials" ]]; then
                    echo "Error: Failed to retrieve credentials after running aws sso login."
                    return 1 2>/dev/null || exit 1
                fi
            else
                return 1 2>/dev/null || exit 1
            fi
        else
            return 1 2>/dev/null || exit 1
        fi
    fi

    echo "Loading credentials..."
    eval "$credentials"

    echo
    echo "Logged in successfully."
    echo "Current identity:"
    aws sts get-caller-identity
}

# Run the main function and then clean it up
_awsp_main
unset -f _awsp_main