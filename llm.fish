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

    # Parse arguments
    set -l model $llm_default_model
    set -l yolo_mode $llm_default_yolo
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
            echo "  Keys: model, yolo" >&2
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
        echo "  --set-default <key> <value>  Set default setting" >&2
        return 1
    end

    # Build the prompt from remaining args
    set -l prompt (string join " " -- $prompt_args)

    # Build the system prompt with environment context
    set -l os_info (uname -srm)
    set -l system_prompt "You translate natural language into shell commands.

ENVIRONMENT:
- Shell: fish
- OS: $os_info
- Working directory: $PWD

RULES:
1. Output ONLY the raw command — no markdown, no code blocks, no backticks
2. If clarification is needed or no command applies, respond with a single line starting with '# '
3. Prefer fish-compatible syntax when relevant

EXAMPLES:
Good: ls -la
Good: # Could you clarify what you mean?
Bad: \`\`\`bash
ls -la
\`\`\`
Bad: \`ls -la\`"

    # Execute claude and capture output
    set -l result
    if test "$yolo_mode" = "on"
        set result (claude --print --model $model --system-prompt $system_prompt --no-session-persistence --dangerously-skip-permissions $prompt 2>&1)
    else
        set result (claude --print --model $model --system-prompt $system_prompt --no-session-persistence $prompt 2>&1)
    end
    set -l claude_status $status

    if test $claude_status -ne 0
        echo "Error executing claude:" >&2
        echo "$result" >&2
        return $claude_status
    end

    # Check if result is a comment
    if string match -qr "^#" "$result"
        # Output comment verbatim
        echo "$result"
        return 0
    end

    # Print the command that will be/would be executed
    if test "$yolo_mode" = "on"
        # Print what we're executing first
        echo "# $result" >&2
        # Execute the command
        fish -c $result
    else if not status is-interactive; or not isatty stdin
        # Non-interactive: just print the command
        echo "$result"
    else
        # Interactive mode: show menu
        _llm_interactive_menu $result $model $system_prompt $prompt
    end
end

function _llm_interactive_menu --description "Interactive menu for llm command confirmation"
    set -l result $argv[1]
    set -l model $argv[2]
    set -l system_prompt $argv[3]
    set -l original_prompt $argv[4..-1]

    while true
        # Display the command with styling
        echo ""
        set_color --bold cyan
        echo "  $result"
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
                echo "  # $result"
                set_color normal
                echo ""
                fish -c $result
                return $status

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
                set -l refine_prompt "Original request: $original_prompt
Previous suggested command: $result
User refinement: $refinement

Based on the refinement, output the updated command."

                # Call claude again with refinement
                set_color brblack
                echo "  Thinking..."
                set_color normal

                set -l new_result (claude --print --model $model --system-prompt $system_prompt --no-session-persistence $refine_prompt 2>&1)
                set -l claude_status $status

                if test $claude_status -ne 0
                    set_color red
                    echo "  Error: $new_result"
                    set_color normal
                    continue
                end

                # Check if new result is a comment
                if string match -qr "^#" "$new_result"
                    echo ""
                    set_color yellow
                    echo "  $new_result"
                    set_color normal
                    return 0
                end

                # Update result and loop back to show menu
                set result $new_result

            case '*'
                set_color brblack
                echo "  Invalid choice. Please enter y, n, or r."
                set_color normal
        end
    end
end
