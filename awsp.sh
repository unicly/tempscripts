#!/usr/bin/env bash

# We wrap the core logic in a function to avoid polluting the user's shell with local variables when sourced.
_awsp_main() {
    local script_path="${1:-}"
    local CONFIG_FILE="${HOME}/.aws/config"
    local profiles=()
    local line
    local profile
    local credentials
    local response
    local PS3="Choose a profile number: "

    # Detect if the script is sourced or run directly
    local is_sourced=false
    if [[ -n "${BASH_VERSION:-}" ]]; then
        if [[ "${BASH_SOURCE[0]:-}" != "${0:-}" ]]; then
            is_sourced=true
        fi
    elif [[ -n "${ZSH_VERSION:-}" ]]; then
        if [[ "${ZSH_EVAL_CONTEXT:-}" == *file* ]]; then
            is_sourced=true
        fi
    fi

    if [[ "$is_sourced" = false ]]; then
        echo "Error: This script must be sourced to set environment variables in your current shell."
        echo "Please run:"
        echo "    source $script_path"
        echo "or:"
        echo "    . $script_path"
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

    # Display the profiles in a vertical list
    local idx=1
    local p
    for p in "${profiles[@]}"; do
        printf "%2d) %s\n" "$idx" "$p"
        idx=$((idx + 1))
    done
    echo

    # Prompt user to select a profile
    local selection=""
    local num_profiles=${#profiles[@]}
    while true; do
        if [[ -n "${ZSH_VERSION:-}" ]]; then
            read -r "selection?$PS3"
        else
            read -r -p "$PS3" selection
        fi

        # Validate that the selection is a positive integer and within range
        if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= num_profiles )); then
            # Find the selected profile in a cross-shell compatible way
            local search_idx=1
            for p in "${profiles[@]}"; do
                if [[ "$search_idx" -eq "$selection" ]]; then
                    profile="$p"
                    break 2
                fi
                search_idx=$((search_idx + 1))
            done
        fi
        echo "Invalid selection. Please choose a valid number."
    done

    if [[ "$profile" == "Cancel" ]]; then
        echo "Cancelled."
        return 0 2>/dev/null || exit 0
    fi

    echo
    echo "Selected profile: $profile"
    echo

    # Unset existing AWS environment variables to prevent conflicts
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION AWS_PROFILE

    # Obtain credentials
    credentials=$(aws configure export-credentials --profile "$profile" --format env)
    if [[ $? -ne 0 ]] || [[ -z "$credentials" ]]; then
        # Check if it is an SSO profile and log in automatically
        if grep -A 10 "\[profile \"\?$profile\"\?\]" "$CONFIG_FILE" 2>/dev/null | grep -E -q "sso_start_url|sso_session"; then
            echo "SSO session expired or not logged in. Launching 'aws sso login'..."
            aws sso login --profile "$profile"
            
            # Try obtaining credentials again
            credentials=$(aws configure export-credentials --profile "$profile" --format env)
            if [[ $? -ne 0 ]] || [[ -z "$credentials" ]]; then
                echo "Error: Failed to retrieve credentials even after logging in."
                return 1 2>/dev/null || exit 1
            fi
        else
            echo "Error: Failed to retrieve credentials for profile '$profile'."
            return 1 2>/dev/null || exit 1
        fi
    fi

    echo "Loading credentials..."
    eval "$credentials"

    echo
    echo "Verifying credentials with AWS..."
    if ! aws sts get-caller-identity >/dev/null; then
        echo "Error: Loaded credentials are invalid (failed validation with AWS)."
        echo "Unsetting AWS environment variables to keep your terminal session clean..."
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION AWS_PROFILE
        return 1 2>/dev/null || exit 1
    fi

    echo "Logged in successfully."
    echo "Current identity:"
    aws sts get-caller-identity
}

# Run the main function and then clean it up
_awsp_main "${BASH_SOURCE[0]:-${0:-}}"
unset -f _awsp_main