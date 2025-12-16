# llm.fish - Translate natural language to shell commands using Claude
#
# The simplest possible implementation: one file, no dependencies beyond
# Claude Code, no configuration files, no package managers. Just copy and go.
#
# Repository: https://github.com/avafloww/llm.fish
# License: WTFPL

function llm --description "Translate natural language to shell commands using Claude"
    # Default settings using universal variables
    set -q llm_default_model; or set -U llm_default_model sonnet
    set -q llm_default_yolo; or set -U llm_default_yolo off
    set -q llm_default_fix; or set -U llm_default_fix on

    # Parse arguments
    set -l model $llm_default_model
    set -l yolo_mode $llm_default_yolo
    set -l fix_mode $llm_default_fix
    set -l verbose_mode off
    set -l prompt_args
    set -l handling_set_default false
    set -l set_default_key ""

    # Handle --help flag early
    if contains -- --help $argv; or contains -- -h $argv
        echo "Usage: llm [options] <prompt>" >&2
        echo "" >&2
        echo "Options:" >&2
        echo "  --model <model>      Use specific model (sonnet, opus, haiku)" >&2
        echo "  --yolo               Execute command immediately" >&2
        echo "  --no-yolo            Don't execute, just print command" >&2
        echo "  --fix                Offer to fix failed commands (default)" >&2
        echo "  --no-fix             Don't offer to fix failed commands" >&2
        echo "  --verbose, -v        Show model and execution time after output" >&2
        echo "  --set-default <key> <value>  Set default setting" >&2
        echo "  --help, -h           Show this help message" >&2
        echo "" >&2
        echo "Behavior:" >&2
        echo "  Interactive:     Shows menu to execute, cancel, or refine" >&2
        echo "  Non-interactive: Prints command only (for piping)" >&2
        echo "  Yolo mode:       Executes immediately without confirmation" >&2
        echo "" >&2
        echo "Current defaults:" >&2
        echo "  Model: $llm_default_model" >&2
        echo "  Yolo mode: $llm_default_yolo" >&2
        echo "  Fix mode: $llm_default_fix" >&2
        return 0
    end

    for arg in $argv
        if test "$handling_set_default" = "true"
            # Handle --set-default arguments
            if test -z "$set_default_key"
                set set_default_key $arg
            else
                switch $set_default_key
                    case model
                        set -U llm_default_model $arg
                        echo "Default model set to: $arg" >&2
                        return 0
                    case yolo
                        if test "$arg" = "on" -o "$arg" = "true" -o "$arg" = "yes"
                            set -U llm_default_yolo on
                            echo "Default yolo mode: enabled" >&2
                        else if test "$arg" = "off" -o "$arg" = "false" -o "$arg" = "no"
                            set -U llm_default_yolo off
                            echo "Default yolo mode: disabled" >&2
                        else
                            echo "Error: yolo mode must be 'on' or 'off'" >&2
                            return 1
                        end
                        return 0
                    case fix
                        if test "$arg" = "on" -o "$arg" = "true" -o "$arg" = "yes"
                            set -U llm_default_fix on
                            echo "Default fix mode: enabled" >&2
                        else if test "$arg" = "off" -o "$arg" = "false" -o "$arg" = "no"
                            set -U llm_default_fix off
                            echo "Default fix mode: disabled" >&2
                        else
                            echo "Error: fix mode must be 'on' or 'off'" >&2
                            return 1
                        end
                        return 0
                    case '*'
                        echo "Error: unknown setting '$set_default_key'" >&2
                        return 1
                end
            end
        else if string match -q -- "--set-default" $arg
            set handling_set_default true
        else if string match -qr -- "^--model=" $arg
            set model (string replace -- "--model=" "" $arg)
        else if string match -q -- "--model" $arg
            # Next arg will be the model
            set -l idx (contains -i -- $arg $argv)
            set -l next_idx (math $idx + 1)
            if test $next_idx -le (count $argv)
                set model $argv[$next_idx]
            end
        else if string match -q -- "--yolo" $arg
            set yolo_mode on
        else if string match -q -- "--no-yolo" $arg
            set yolo_mode off
        else if string match -q -- "--fix" $arg
            set fix_mode on
        else if string match -q -- "--no-fix" $arg
            set fix_mode off
        else if string match -q -- "--verbose" $arg; or string match -q -- "-v" $arg
            set verbose_mode on
        else
            # Check if previous arg was --model (skip this if it's the model value)
            set -l idx (contains -i -- $arg $argv)
            set -l prev_idx (math $idx - 1)
            if test $prev_idx -ge 1; and string match -q -- "--model" $argv[$prev_idx]
                # This is the model value, skip it
            else
                set -a prompt_args $arg
            end
        end
    end

    # Check if we need more args for --set-default
    if test "$handling_set_default" = "true"
        if test -z "$set_default_key"
            echo "Usage: llm --set-default <key> <value>" >&2
            echo "  Keys: model, yolo, fix" >&2
            return 1
        else
            echo "Error: missing value for --set-default $set_default_key" >&2
            return 1
        end
    end

    # Check if we have a prompt
    if test (count $prompt_args) -eq 0
        echo "Usage: llm [options] <prompt>" >&2
        echo "Options:" >&2
        echo "  --model <model>      Use specific model (sonnet, opus, haiku)" >&2
        echo "  --yolo               Execute command immediately" >&2
        echo "  --no-yolo            Don't execute, just print command" >&2
        echo "  --verbose, -v        Show model and execution time" >&2
        echo "  --set-default <key> <value>  Set default setting" >&2
        return 1
    end

    # Build the prompt from remaining args
    set -l prompt (string join " " -- $prompt_args)

    # Build the system prompt with environment context
    set -l os_info (uname -srm)
    set -l user_info (id -un)
    set -l group_info (id -gn)
    set -l is_root (test (id -u) -eq 0; and echo "yes (no sudo needed)"; or echo "no (use sudo for privileged commands)")
    set -l system_prompt "You translate natural language into shell commands.

ENVIRONMENT:
- Shell: fish
- OS: $os_info
- User: $user_info (group: $group_info)
- Home: $HOME
- Working directory: $PWD
- Root: $is_root

CRITICAL: Your output is piped directly to a shell. Any non-command text will break execution.

RULES:
1. Output ONLY executable commands OR shell comments (lines starting with '# ')
2. NEVER use markdown: no \`\`\`, no \`backticks\`, no code fences
3. ANY text that is not an executable command MUST start with '# ' (shell comment)
4. This includes: clarifications, questions, explanations, errors, warnings, notes
5. Prefer fish-compatible syntax
6. ALWAYS output an actual command. Only use comment-only responses for genuinely dangerous operations (rm -rf /, etc.) or truly impossible requests. When in doubt, output your best guess at the command.

CORRECT OUTPUT:
ls -la
echo \"hello world\"
# I need more information about what you want
# This will delete all files in the current directory

WRONG OUTPUT (never do this):
\`\`\`fish
ls -la
\`\`\`
\`ls -la\`
Here's the command: ls -la
I'll help you with that: ls -la
Let me output the command:
Sure, here you go:
Note: this will delete files

START YOUR RESPONSE WITH THE COMMAND ITSELF. No preamble, no introduction, just the command or a # comment."

    # Execute claude and capture output
    # Use string collect to preserve newlines (otherwise fish splits into a list)
    set -l start_time (date +%s)
    set -l result
    if test "$yolo_mode" = "on"
        set result (claude --print --model "$model" --system-prompt "$system_prompt" --no-session-persistence --dangerously-skip-permissions -- "$prompt" 2>&1 | string collect)
    else
        set result (claude --print --model "$model" --system-prompt "$system_prompt" --no-session-persistence -- "$prompt" 2>&1 | string collect)
    end
    set -l claude_status $status
    set -l end_time (date +%s)
    set -l elapsed_time (math $end_time - $start_time)

    if test $claude_status -ne 0
        echo "Error executing claude:" >&2
        printf '%s\n' $result >&2
        return $claude_status
    end

    # Strip markdown formatting that LLMs sometimes add despite instructions
    # $result is a list of lines (fish splits command output by newlines)
    # Pass list directly to function, capture output as new list
    set result (_llm_strip_markdown $result)

    # Print the command that will be/would be executed
    if test "$yolo_mode" = "on"
        # In yolo mode, comments are just printed (not executed)
        if string match -qr "^#" "$result[1]"
            if test "$verbose_mode" = "on"
                printf '\e[90m# model: %s, time: %ss\e[m\n\n' $model $elapsed_time >&2
            end
            printf '%s\n' $result
            return 0
        end
        # Print what we're executing first
        if test "$verbose_mode" = "on"
            printf '\e[90m# model: %s, time: %ss\e[m\n\n' $model $elapsed_time >&2
        end
        # Don't double-prefix lines that already start with #
        for line in $result
            if string match -q '#*' -- "$line"
                echo "$line" >&2
            else
                echo "# $line" >&2
            end
        end
        # Execute the command
        fish -c (string join \n -- $result)
    else if not status is-interactive; or not isatty stdin
        # Non-interactive: just print the command
        if test "$verbose_mode" = "on"
            set_color brblack
            echo "# model: $model, time: "$elapsed_time"s"
            set_color normal
            echo ""
        end
        printf '%s\n' $result
    else
        # Interactive mode: show menu
        # Use unit separator (\x1f) to join lines - fish splits command substitution by newlines,
        # so we need a different delimiter to preserve multi-line content as a single argument
        _llm_interactive_menu (string join \x1f -- $result) "$model" "$system_prompt" "$prompt" "$verbose_mode" "$elapsed_time" "$os_info" "$fix_mode"
    end
end

function _llm_interactive_menu --description "Interactive menu for llm command confirmation"
    # Split by unit separator to recover the original lines
    set -l result (string split \x1f -- $argv[1])
    set -l model $argv[2]
    set -l system_prompt $argv[3]
    set -l original_prompt $argv[4]
    set -l verbose_mode $argv[5]
    set -l elapsed_time $argv[6]
    set -l os_info $argv[7]
    set -l fix_mode $argv[8]

    # Detect platform from os_info (e.g., "Darwin 23.0.0 arm64" or "Linux 6.1.0 x86_64")
    set -l os_type (string split ' ' -- $os_info)[1]

    while true
        # Display verbose info if enabled
        if test "$verbose_mode" = "on"
            set_color brblack
            echo "  # model: $model, time: "$elapsed_time"s"
            set_color normal
        end

        # Display the command with styling
        echo ""
        set_color --bold cyan
        string split '\n' -- $result | string replace -r '^' '  '
        set_color normal
        echo ""

        # Draw separator
        set_color brblack
        echo "  ─────────────────────────────────────────────────"
        set_color normal

        # Show options
        echo ""
        set_color green
        printf "  [y]"
        set_color normal
        printf " Execute"

        printf "    "

        set_color red
        printf "[n]"
        set_color normal
        printf " Cancel"

        printf "    "

        set_color yellow
        printf "[r]"
        set_color normal
        printf " Refine"

        echo ""
        echo ""

        # Prompt for input
        read -P '  > ' -l choice

        switch $choice
            case y Y yes Yes YES
                echo ""
                set_color brblack
                # Show what we're executing - don't double-prefix lines that already start with #
                for line in $result
                    if string match -q '#*' -- "$line"
                        echo "  $line"
                    else
                        echo "  # $line"
                    end
                end
                set_color normal
                echo ""

                # Execute with script to capture output while preserving TTY
                set -l tmpfile (mktemp)

                # Join result list into a single command string
                set -l cmd_string (string join \n -- $result)

                if test "$os_type" = "Darwin"
                    # macOS: script -q <outfile> <command...>
                    script -q $tmpfile fish -c "$cmd_string"
                else
                    # Linux: script -q -c <command> <outfile>
                    # Escape single quotes for sh parsing
                    set -l escaped (string replace -a "'" "'\\''" -- "$cmd_string")
                    script -q -c "fish -c '$escaped'" $tmpfile
                end

                set -l cmd_status $status
                set -l cmd_output (cat $tmpfile)
                rm -f $tmpfile

                # Check for errors: non-zero exit OR error patterns in output
                set -l has_error false
                set -l error_reason ""
                if test $cmd_status -ne 0
                    set has_error true
                    set error_reason "exit code $cmd_status"
                else if _llm_detect_error "$cmd_output"
                    set has_error true
                    set error_reason "error detected in output"
                end

                # If error detected and fix mode is enabled, offer to fix
                if test "$has_error" = "true" -a "$fix_mode" = "on"
                    echo ""
                    set_color brblack
                    echo "  ─────────────────────────────────────────────────"
                    set_color normal
                    echo ""
                    set_color red
                    printf "  Command failed (%s). " $error_reason
                    set_color normal
                    set_color yellow
                    printf "[f]"
                    set_color normal
                    printf " Fix    "
                    set_color brblack
                    printf "[enter]"
                    set_color normal
                    printf " Ignore"
                    echo ""
                    echo ""

                    read -P '  > ' -l fix_choice

                    switch $fix_choice
                        case f F fix Fix FIX
                            # Build context for fixing
                            set -l result_str (string join \n -- $result)
                            set -l fix_prompt "Original request: $original_prompt
Executed command: $result_str
Command failed ($error_reason)
Output:
$cmd_output

Analyze the error and output a corrected command."

                            set_color brblack
                            echo ""
                            echo "  Thinking..."
                            set_color normal

                            set -l fix_start_time (date +%s)
                            set -l new_result (claude --print --model "$model" --system-prompt "$system_prompt" --no-session-persistence -- "$fix_prompt" 2>&1 | string collect)
                            set -l claude_status $status
                            set -l fix_end_time (date +%s)
                            set elapsed_time (math $fix_end_time - $fix_start_time)

                            if test $claude_status -ne 0
                                set_color red
                                printf '  Error: %s\n' $new_result
                                set_color normal
                                return $cmd_status
                            end

                            # Strip markdown formatting
                            set new_result (_llm_strip_markdown $new_result)

                            # Update result and loop back to show menu
                            set result $new_result
                            continue

                        case '*'
                            # Ignore - return the original exit status
                            return $cmd_status
                    end
                end

                return $cmd_status

            case n N no No NO ''
                set_color brblack
                echo "  Cancelled."
                set_color normal
                return 1

            case r R refine Refine REFINE
                echo ""
                read -P '  Refine: ' -l refinement

                if test -z "$refinement"
                    set_color brblack
                    echo "  No refinement provided, showing menu again."
                    set_color normal
                    continue
                end

                # Build context for refinement
                set -l result_str (string join \n -- $result)
                set -l refine_prompt "Original request: $original_prompt
Previous suggested command: $result_str
User refinement: $refinement

Based on the refinement, output the updated command."

                # Call claude again with refinement
                set_color brblack
                echo "  Thinking..."
                set_color normal

                set -l refine_start_time (date +%s)
                set -l new_result (claude --print --model "$model" --system-prompt "$system_prompt" --no-session-persistence -- "$refine_prompt" 2>&1 | string collect)
                set -l claude_status $status
                set -l refine_end_time (date +%s)
                set elapsed_time (math $refine_end_time - $refine_start_time)

                if test $claude_status -ne 0
                    set_color red
                    printf '  Error: %s\n' $new_result
                    set_color normal
                    continue
                end

                # Strip markdown formatting
                set new_result (_llm_strip_markdown $new_result)

                # Update result and loop back to show menu
                set result $new_result

            case '*'
                set_color brblack
                echo "  Invalid choice. Please enter y, n, or r."
                set_color normal
        end
    end
end

function _llm_strip_markdown --description "Strip markdown code formatting from LLM output"
    # Input is a list of lines (fish naturally splits command output by newlines)
    set -l lines $argv

    # Remove empty lines at start
    while test (count $lines) -gt 0; and test -z "$lines[1]"
        set lines $lines[2..-1]
    end

    # Remove empty lines at end
    while test (count $lines) -gt 0; and test -z "$lines[-1]"
        set lines $lines[1..-2]
    end

    # Check if first line is a code fence opener (```lang or just ```)
    if test (count $lines) -gt 0; and string match -qr '^```' -- "$lines[1]"
        set lines $lines[2..-1]
    end

    # Check if last line is a code fence closer
    if test (count $lines) -gt 0; and string match -q '```' -- "$lines[-1]"
        set lines $lines[1..-2]
    end

    # If single line with surrounding backticks, strip them
    if test (count $lines) -eq 1
        set lines (string replace -r '^`([^`]+)`$' '$1' -- "$lines[1]")
    end

    # Output each line (caller will capture as list)
    printf '%s\n' $lines
end

function _llm_detect_error --description "Check if output contains error patterns"
    # Returns 0 (true) if error patterns detected, 1 (false) otherwise
    set -l output $argv[1]

    # Common error patterns (case insensitive)
    string match -riq '(?:^|\s)error:' -- $output; and return 0
    string match -riq 'command not found' -- $output; and return 0
    string match -riq 'no such file or directory' -- $output; and return 0
    string match -riq 'permission denied' -- $output; and return 0
    string match -riq '(?:^|\s)fatal:' -- $output; and return 0
    string match -riq 'failed to' -- $output; and return 0
    string match -riq 'cannot ' -- $output; and return 0
    string match -riq 'unable to' -- $output; and return 0
    string match -riq 'not found$' -- $output; and return 0
    string match -riq 'unknown option' -- $output; and return 0
    string match -riq 'invalid option' -- $output; and return 0
    string match -riq 'unrecognized option' -- $output; and return 0
    string match -riq 'syntax error' -- $output; and return 0
    string match -riq 'undefined variable' -- $output; and return 0

    return 1
end
