status is-interactive || exit

set --global _hydro_vcs _hydro_vcs_$fish_pid

function $_hydro_vcs --on-variable $_hydro_vcs
    commandline --function repaint
end

function _hydro_pwd --on-variable PWD --on-variable hydro_ignored_git_paths --on-variable hydro_ignored_jj_paths --on-variable fish_prompt_pwd_dir_length
    set --local vcs_root
    set --local vcs_base
    set --local vcs_type

    # Check for jj
    if command -q jj
        set vcs_root (command jj root --ignore-working-copy 2>/dev/null)
        if set --query vcs_root[1]
            set vcs_type jj
            set vcs_base (string replace --all --regex -- "^.*/" "" "$vcs_root")
        end
    end

    # Fallback to git
    if not set --query vcs_root[1]
        set vcs_root (command git --no-optional-locks rev-parse --show-toplevel 2>/dev/null)
        if set --query vcs_root[1]
            set vcs_type git
            set vcs_base (string replace --all --regex -- "^.*/" "" "$vcs_root")
        end
    end

    set --local path_sep /
    test "$fish_prompt_pwd_dir_length" = 0 && set path_sep

    # Check ignore paths based on VCS type
    set --local should_skip
    if test "$vcs_type" = "jj" && contains -- $vcs_root $hydro_ignored_jj_paths
        set should_skip true
    else if test "$vcs_type" = "git" && contains -- $vcs_root $hydro_ignored_git_paths
        set should_skip true
    end

    if set --query vcs_root[1] && not set --query should_skip[1]
        set --erase _hydro_skip_vcs_prompt
        set --global _hydro_vcs_type $vcs_type
    else
        set --global _hydro_skip_vcs_prompt
        set --erase _hydro_vcs_type
    end

    set --global _hydro_pwd (
        string replace --ignore-case -- ~ \~ $PWD |
        string replace -- "/$vcs_base/" /:/ |
        string replace --regex --all -- "(\.?[^/]{"(
            string replace --regex --all -- '^$' 1 "$fish_prompt_pwd_dir_length"
        )"})[^/]*/" "\$1$path_sep" |
        string replace -- : "$vcs_base" |
        string replace --regex -- '([^/]+)$' "\x1b[1m\$1\x1b[22m" |
        string replace --regex --all -- '(?!^/$)/|^$' "\x1b[2m/\x1b[22m"
    )
end

function _hydro_postexec --on-event fish_postexec
    set --local last_status $pipestatus
    set --global _hydro_status "$_hydro_newline$_hydro_color_prompt$hydro_symbol_prompt"

    for code in $last_status
        if test $code -ne 0
            set --global _hydro_status "$_hydro_color_error| "(echo $last_status)" $_hydro_newline$_hydro_color_prompt$_hydro_color_error$hydro_symbol_prompt"
            break
        end
    end

    test "$CMD_DURATION" -lt $hydro_cmd_duration_threshold && set _hydro_cmd_duration && return

    set --local secs (math --scale=1 $CMD_DURATION/1000 % 60)
    set --local mins (math --scale=0 $CMD_DURATION/60000 % 60)
    set --local hours (math --scale=0 $CMD_DURATION/3600000)

    set --local out

    test $hours -gt 0 && set --local --append out $hours"h"
    test $mins -gt 0 && set --local --append out $mins"m"
    test $secs -gt 0 && set --local --append out $secs"s"

    set --global _hydro_cmd_duration "$out "
end

function _hydro_prompt --on-event fish_prompt
    set --query _hydro_status || set --global _hydro_status "$_hydro_newline$_hydro_color_prompt$hydro_symbol_prompt"
    set --query _hydro_pwd || _hydro_pwd

    command kill $_hydro_last_pid 2>/dev/null

    set --query _hydro_skip_vcs_prompt && set $_hydro_vcs && return

    if test "$_hydro_vcs_type" = "jj"
        fish --private --command "
            set -l change_id (
              command jj log --revisions @ --no-graph --ignore-working-copy --color always --limit 1 --template 'change_id.shortest(4)' \
              2>/dev/null
            )
            set -l current_plain_id (
              command jj log --revisions @ --no-graph --ignore-working-copy --color never --limit 1 --template 'change_id' \
              2>/dev/null
            )

            set -l closest_bookmark (
              command jj log --revisions 'heads(::@ & bookmarks())' --no-graph --ignore-working-copy --limit 1 --template \"
                if(stringify(change_id) == '\$current_plain_id', bookmarks, label('bookmark', surround('(', ')', bookmarks)))
              \" 2>/dev/null
            )

            set -l info (
              command jj log --revisions @ --no-graph --ignore-working-copy --color always --limit 1 --template \"
                separate(' ',
                  concat(
                    if(conflict, '$hydro_symbol_jj_conflict'),
                    if(divergent, '$hydro_symbol_jj_divergent'),
                    if(hidden, '$hydro_symbol_jj_hidden'),
                    if(immutable, '$hydro_symbol_jj_immutable'),
                  ),
                  raw_escape_sequence('\x1b[1;32m') ++ if(empty, '(empty)'),
                  raw_escape_sequence('\x1b[1;32m') ++ if(description.first_line().len() == 0,
                    '(no description set)',
                    if(description.first_line().substr(0, 29) == description.first_line(),
                      description.first_line(),
                      description.first_line().substr(0, 29) ++ '…',
                    )
                  ) ++ raw_escape_sequence('\x1b[0m'),
                )
              \" 2>/dev/null
            )

            set -l branch (echo \"@\$change_id \$closest_bookmark \$info\")

            test -z \"\$$_hydro_vcs\" && set --universal $_hydro_vcs \"\$branch \"

            for fetch in $hydro_fetch false
                set --universal $_hydro_vcs \"\$branch \"
            end
        " &
    else
        fish --private --command "
            set -l branch (
                command git symbolic-ref --short HEAD 2>/dev/null ||
                command git describe --tags --exact-match HEAD 2>/dev/null ||
                command git rev-parse --short HEAD 2>/dev/null |
                    string replace --regex -- '(.+)' '@\$1'
            )

            test -z \"\$$_hydro_vcs\" && set --universal $_hydro_vcs \"\$branch \"

            command git diff-index --quiet HEAD 2>/dev/null
            test \$status -eq 1 ||
                count (command git ls-files --others --exclude-standard (command git rev-parse --show-toplevel)) >/dev/null && set info \"$hydro_symbol_git_dirty\"

            for fetch in $hydro_fetch false
                command git rev-list --count --left-right @{upstream}...@ 2>/dev/null |
                    read behind ahead

                switch \"\$behind \$ahead\"
                    case \" \" \"0 0\"
                    case \"0 *\"
                        set upstream \" $hydro_symbol_git_ahead\$ahead\"
                    case \"* 0\"
                        set upstream \" $hydro_symbol_git_behind\$behind\"
                    case \*
                        set upstream \" $hydro_symbol_git_ahead\$ahead $hydro_symbol_git_behind\$behind\"
                end

                set --universal $_hydro_vcs \"\$branch\$info\$upstream \"

                test \$fetch = true && command git fetch --no-tags 2>/dev/null
            end
        " &
    end

    set --global _hydro_last_pid $last_pid
end

function _hydro_fish_exit --on-event fish_exit
    set --erase $_hydro_vcs
end

function _hydro_uninstall --on-event hydro_uninstall
    set --names |
        string replace --filter --regex -- "^(_?hydro_)" "set --erase \$1" |
        source
    functions --erase (functions --all | string match --entire --regex "^_?hydro_")
end

set --global hydro_color_normal (set_color normal)

for color in hydro_color_{pwd,vcs,error,prompt,duration,start}
    function $color --on-variable $color --inherit-variable color
        set --query $color && set --global _$color (set_color $$color)
    end && $color
end

function hydro_multiline --on-variable hydro_multiline
    if test "$hydro_multiline" = true
        set --global _hydro_newline "\n"
    else
        set --global _hydro_newline ""
    end
end && hydro_multiline

set --query hydro_color_error || set --global hydro_color_error $fish_color_error
set --query hydro_symbol_prompt || set --global hydro_symbol_prompt ❱
set --query hydro_symbol_git_dirty || set --global hydro_symbol_git_dirty •
set --query hydro_symbol_git_ahead || set --global hydro_symbol_git_ahead ↑
set --query hydro_symbol_git_behind || set --global hydro_symbol_git_behind ↓
set --query hydro_symbol_jj_conflict || set --global hydro_symbol_jj_conflict 💥
set --query hydro_symbol_jj_divergent || set --global hydro_symbol_jj_divergent 🚧
set --query hydro_symbol_jj_hidden || set --global hydro_symbol_jj_hidden 👻
set --query hydro_symbol_jj_immutable || set --global hydro_symbol_jj_immutable 🔒
set --query hydro_multiline || set --global hydro_multiline false
set --query hydro_cmd_duration_threshold || set --global hydro_cmd_duration_threshold 1000
