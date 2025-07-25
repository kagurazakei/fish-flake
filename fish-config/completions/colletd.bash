#!/usr/bin/env bash
# Include this to get shell-script-mode to detect bash

function _nix_print () {
    return 0 # Comment out to turn on print debugging
    while [[ "$1" ]]; do
        echo  "$1" >> ~/log/nix
        shift
    done
}

function _nix_attr_paths () {

    local cur=${cur#@(\'|\")}
    cur=${cur%@(\'|\")}
    # Starting with '.' means we want files, not attribute names
    if [[ "$cur" == .* ]]; then
        return
    fi

    # The unnamed top context to look up attribute names
    local defexpr="$1"

    # The known valid part of the attribute path, eg. 'nixpkgs', if the
    # currently typed word is 'nixpkgs.mp'
    local attr_path=""
    if [[ -z ${cur/*.*/} ]]; then
        attr_path=${cur%.*}
    fi

    # attr1.attr3 -> ("attr1" "attr2")
    local -a paths=(${attr_path//./ })
    paths=(${paths[*]/%/\"})
    paths=(${paths[*]/#/\"})

    # Auto call any functions in the attribute path. This isn't a language
    # feature, but done by nix when passing attributes on the command line.
    local -a packages=($(_nix_eval_stdin <<NIX_FILE
        let
          autocall = setOrLambda:
              if builtins.isFunction setOrLambda then
                 setOrLambda {}
              else
                 setOrLambda;

          top = autocall ($defexpr);
          names = [ ${paths[*]} ];

          # Returns attr.name calling it if it's a function
          reducer = set: name:
              autocall (builtins.getAttr name set);
          result = builtins.foldl' reducer top names;
        in
          if builtins.isAttrs result then
            builtins.attrNames result
          else
            ""
NIX_FILE
    ))

    # Don't insert space as we'll too often have to backspace and add a '.'
    compopt -o nospace
    # Generate the completion list prefixed with $attr_path and match against
    # the current word
    COMPREPLY=( $(compgen -P "${attr_path:+${attr_path}.}" -W "${packages[*]}" \
                          -- "${cur##*.}"))
}

function _nix_eval_stdin () {
    # Build up a modified NIX_PATH using -I and --include
    local i override=""
    for ((i=1; i < ${#words[*]}; i++)); do
        case "${words[i]}" in
            -I|--include)
                override+=${override:+:}${words[$((i+1))]}
                ;;
        esac
    done
    override+=${override:+:}${NIX_PATH}

    # Resolve channel: syntax
    while [[ "$override" == *@(=|:)channel:* ]]; do
        local channel=${override#*channel:}
        channel="channel:"${channel%%:*}
        local url="https://nixos.org/channels/"${channel:8}"/nixexprs.tar.xz"
        override=${override/"$channel"/"$url"}
    done

    # Resolve any url to a cache, else we might trigger a blocking download
    while [[ "$override" == *https://* ]]; do
        # Find the first url
        local url=${override#*https://}
        # Strip everything starting with the first colon
        url="https://"${url%%:*}
        local cache=$(_nix_resolve_url "$url")
        # Replace the url with the cache
        override=${override/"$url"/"$cache"}
    done

    # Eval stdin
    # Shortcut: since the output of this function is only used in the -W argument of compgen,
    # which expects a shell-quoted list of words, we leave the double quotes from the Nix
    # output intact to approximate shell quoting.
    NIX_PATH=$override nix-instantiate --eval - 2> /dev/null | tr '[]' ' '
}

# Resolve any urls ourselves, as nix will start downloading and block
# interaction if it's left to its own devices
function _nix_resolve_url () {
    local url=$1
    local version="$(${words[0]} --version)"
    local input
    if [[ "${version##* }" == 1.11.* ]]; then
        # works for nix 1.11
        input="$url"
    else
        # works for nix 1.12
        input="${url##*/}\0$url"
    fi
    local sha
    sha=$(nix-hash --flat --base32 --type sha256 <(printf "$input"))
    local cache=${XDG_CACHE_HOME:-~/.cache}/nix/tarballs
    local link="$cache"/"$sha"-file
    if [[ -e "$link" ]]; then
        echo "$cache/$(basename $(readlink $link))-unpacked"
    fi
}

# Get the correct file like argument from the command line
function _nix_get_file_arg () {
    local file=""
    if [[ "${words[0]}" == @(nix-env|nix) ]]; then
        local i
        # Extract the last seen -f/--file argument
        for ((i=1; i < ${#words[*]}; i++)); do
            case "${words[i]}" in
                --file|-f)
                    file=${words[$((i+1))]}
                    ;;
            esac
        done
    elif [[ ${line[1]} ]]; then
        file="${line[1]}"
    elif [[ -e shell.nix && "${words[0]}" == nix-shell ]]; then
        file="shell.nix"
    elif [[ -e default.nix ]]; then
        file="default.nix"
    fi

    # Resolve files and urls
    if [[ "$file" ]]; then

        # Expand channel: syntax
        if [[ "$file" == channel:* ]]; then
            file="https://nixos.org/channels/"${file:8}"/nixexprs.tar.xz"
        fi

        # dequote
        file=$(dequote "$file")
        __expand_tilde_by_ref file
        if [[ -e "$file" ]]; then
            file=$(realpath "$file" 2>/dev/null)
        elif [[ "$file" == https://* ]]; then
            # Check the cache to resolve urls
            file=$(_nix_resolve_url "$file")
        fi

    fi
    printf -- "$file"
}

function _parse () {
    # Takes in `spec ...` and parses the command line using it
    # See README.md for more in depth explanation of the syntax

    ## Spec
    # :action -- A regular normal argument
    # :*action -- Repeating normal argument

    ## option spec
    # simple case: '-o'
    # [(pattern|pattern|...)][*]-f[:action[:[*]action ...]]
    # patterns to exclude from completion when option is typed

    ## action spec
    # ->string
    # set $state to 'string'
    # _function, function to run (isn't actually used though, so might be buggy)
    local -A options=()
    local -a arguments=("command")

    # Parse the spec
    local spec="$1"
    local -A groups
    local cur_group=""
    local split group excludes
    while [[ "$spec" ]]; do
        group=""

        excludes=""
        # check for an exclusion group
        # Strip it from $spec if found
        if [[ "$spec" == \(* ]]; then
            excludes=${spec%%\)*}
            excludes=${excludes:1}"#"
            spec="${spec#*\)}"
        fi
        case "$spec" in
            +)
                shift
                cur_group="$1"
            ;;
            -*)
                # exclude the option from itself by default
                local -a split=(${spec/:/ })
                local flag=${split[0]}
                excludes=${flag}${excludes:+\|}${excludes:-\#}
                ;&
            \*-*)
                # Split on first :
                spec="${spec#\*}" # Strip possible star prefix
                local -a split=(${spec/:/ })
                local flag=${split[0]}
                if [[ "$cur_group" ]]; then
                    # Add the flag to the glob group
                    groups[$cur_group]+=${groups[$cur_group]:+|}$flag
                fi
                # Internal representation [group#][excludes#];
                options[$flag]="$excludes:${split[1]}"
                ;;
            :*)
                arguments+=("$spec")
                ;;
        esac
        shift
        spec="$1"
    done
    _nix_print  "    --**--" "-- Finished parsing spec"
    _nix_print  "arguments:" "${arguments[*]}"
    _nix_print "options" "${!options[*]}"
    # _nix_print  groups: ${!groups[*]} ${groups[*]}


    _nix_print  "-- Parse words"
    # Use the parsed spec to handle the input
    # opt_arg queue
    local -a opt_queue=()
    local -a used_options=()
    local current_option=""
    local excluded_options=""
    # The list of completors corresponding to each word in words
    local completors=()
    # Reset all output variables
    line=() opts=() opt_args=() state=""

    local word="" i
    for ((i=0; i < ${#words[*]}; i++)); do
        word=${words[$i]}
        if [[ "${opt_queue[*]}" ]]; then
            # Consume an option argument
            _nix_print "consume option queue: $word ${opt_queue[0]}"
            local separator=${opt_args["$current_option"]:+:}
            opt_args["$current_option"]+=$separator${word//:/\\:}

            local action="${opt_queue[0]}"
            if [[ "$action" == \** ]]; then
                completors+=(${action#\*})
            else
                completors+=(${action})
                opt_queue=(${opt_queue[*]:1})
            fi
        elif [[ "$word" == -* ]]; then
            # Handle options
            _nix_print "Consume option[s]: $word ${options[$word]}"

            completors+=("$word")

            # Reset flags
            local -a flags=()
            if [[ "$word" == --* ]]; then
                flags=("$word")
            else
                local letters=${word#-} j
                for ((j=0; j < ${#letters}; j++)); do
                    flags+=(-${letters:j:1})
                done
            fi

            local flag=""
            for flag in ${flags[*]}; do

                local spec=${options["$flag"]}
                local -a actions=(${spec//:/ })

                # Register the flag being on the command line
                [[ "$spec" ]] && opts[${flag}]=1

                # Check if actions contains an exclusion pattern
                if [[ ${actions[0]} == *\# ]]; then
                    local prefix="${excluded_options:+|}"
                    [[ "$cword" != "$i" || $flag == -? ]] \
                        && excluded_options+="$prefix${actions[0]:0:-1}"
                    _nix_print "$flag's exclusion group:" "$prefix${actions[0]:0:-1}"
                    actions=(${actions[*]:1})
                fi

                # Add any option arguments to the queue
                if [[ "${actions[*]}" ]]; then
                    current_option="$flag"
                    # Add to the option argument queue
                    _nix_print  "option arguments: ${actions[*]}"
                    opt_queue=(${actions[*]})
                    _nix_print  "option queue: ${opt_queue[*]}"
                fi
            done
        else
            # Consume a regular argument
            _nix_print  "Consume a regular argument: $word"
            line+=("$word")
            _nix_print  "Adding completor: ${arguments[0]}"
            # Always add argument completors, even if empty
            local action="${arguments[0]}"
            _nix_print "action: $action"
            if [[ "$action" == :\** ]]; then
                    completors+=("${action#:\*}")
                    # Don't shift $arguments when the action is repeatable
            else
                completors+=("${action#:}")
                arguments=(${arguments[*]:1})
                _nix_print  "rest of arguments: ${arguments[*]}"
            fi
        fi
    done

    _nix_print  "-- Finished parsing words: ${completors[*]}"

    local completor=${completors[$cword]}
    _nix_print  "completor: $completor"

    case "$completor" in
        -\>*)
            state="${completor#->}"
            return 1
            ;;
        -*)
            _nix_print  "excluded_options $excluded_options"
            COMPREPLY=($(compgen -W "${!options[*]}" -X "*($excluded_options)" -- "$cur"))
            return 0
            ;;
        _*)
            $completor
            return 0
            ;;
        "")
            COMPREPLY=($(compgen -W "${!options[*]}" -X "*($excluded_options)" -- "$cur"))
            return 0
            ;;
    esac
}

# Completions for all nix commands
function _nix_completion () {
    local cur prev words cword
    # Setup current word, previous word, words and index of current word in
    # words (cword)
    _init_completion -n =: || return

    _nix_print  "command line: ${words[*]}"
    _nix_print  "number ${#words[*]}"
    _nix_print  "cword $cword"

    local -a nix_boilerplate_opts=('--help' '--version')

    local nix_repair='--repair';

    local nix_search_path_args='*-I:->option-INCLUDE'

    # Misc Nix options accepted by nixos-rebuild
    local -a nix_common_nixos_rebuild=(
        ${nix_search_path_args}
        '(--verbose|-v)'{--verbose,-v}
        '(--no-build-output|-Q)'{--no-build-output,-Q}
        '(--max-jobs|-j)'{--max-jobs,-j}':->empty' '--cores'
        '(--keep-going|-k)'{--keep-going,-k}
        '(--keep-failed|-K)'{--keep-failed,-K}
        '--fallback' '--show-trace'
        ${nix_repair})

    # Used for all the nix-* commands, but not nixos-* commands
    # Introduced in 2.0
    local -a nix_new_opts=(
        '*--include:->option-INCLUDE'
        "*--option:->nixoption:->nixoptionvalue"
    )

    # Used in: nix-build, nix-env, nix-instantiate, nix-shell
    local -a nix_common_opts=(
        ${nix_common_nixos_rebuild[*]}
        ${nix_new_opts[*]}
            '*'{--attr,-A}':->attr_path'
            '*--arg:->function-arg:->empty' '*--argstr:->function-arg:->empty'
            '--max-silent-time:->empty'
            '--timeout:->empty'
            '--readonly-mode'
            '--log-type:->log-type')

    local nix_dry_run='--dry-run'

    local -a nix_gc_common=(
        '(- --print* --delete)--print-roots'
            '(-|--print*|--delete)--print-live'
            '(-|--print*|--delete)--print-dead'
            '(-|--print*|--delete)--delete'
            )

    local state context word opt
    local -a line
    local -A opt_args
    local -A opts

    # Handle the different nix* commands
    #
    # The basic idea is making a spec to pass to _parse then
    # handle any possibly argument completion based on the resulting $state.
    #
    # For some commands like nix-env the spec depends on the flags already
    # typed on the command line.
    #
    # So in general there's three phases:
    # 1. Create the spec, possibly checking for existing flags and commands
    # 2. Pass the spec to parse and let it do its job
    # 3. Generating completions based on the resulting $state
    local -a main_commands=()
    case "${words[0]}" in
        nix-build)
            local -a nix_build_opts=(
                '--drv-link:->empty' '--add-drv-link'
                '(--expr|-E)'{--expr,-E}
                '--no-out-link'
                {--out-link,-o}':->empty')
            _parse ':*->file-or-expr' ${nix_common_opts[*]} \
                   ${nix_boilerplate_opts[*]} \
                   ${nix_build_opts[*]} && return 0
            ;;
        nix-shell)
            local -a nix_shell_opts=(
                '--command:->option-COMMAND'
                '--exclude:->regex'
                '--pure'
                # nix-shell only takes one -A, so override the default
                "(--attr|-A)"{--attr,-A}':->attr_path'
                '(--packages|-p|--expr|-E)'{--expr,-E}
                '(--packages|-p|--expr|-E)'{--packages,-p})

            _parse ':*->package_attr_path' ${nix_common_opts[*]} \
                   + boiler \
                   ${nix_boilerplate_opts[*]} \
                   ${nix_shell_opts[*]} && return 0

            if [[ "$state" == package_attr_path ]]; then
                if [[ "${opts[--packages]}" || "${opts[-p]}" ]]; then
                    _nix_attr_paths "import <nixpkgs>"
                    return 0
                else
                    state=file-or-expr
                fi
            fi
            ;;
        nix-env)
            local -a main_options=(
                {--install,-i} {--upgrade,-u} {--uninstall,-e} --set-flag
                {--query,-q} {--switch-profile,-S}
                --list-generations --delete-generations
                {--switch-generation,-G} --rollback)
            local ex_group="${main_options[*]}"
            ex_group="(${ex_group// /|})"
            local -a main_spec=(
                "$ex_group"{--install,-i} "$ex_group"{--upgrade,-u}
                "$ex_group"{--uninstall,-e}
                "$ex_group"--set-flag":->flag_name:->flag_value"
                "$ex_group"{--query,-q} "$ex_group"{--switch-profile,-S}
                "$ex_group"--list-generations
                "$ex_group"--delete-generations
                "$ex_group"{--switch-generation,-G} "$ex_group"--rollback
            )

            local -a nix_env_common_opts=(
                    ${nix_common_opts[*]}
                    '(--profile|-p)'{--profile,-p}':->profile'
                    $nix_dry_run
                    '--system-filter:->nix-system')

            local -a nix_env_b=('(--prebuilt-only|-b)'{--prebuilt-only,-b})
            local nix_env_from_profile='--from-profile:->profile'

            local -a command_options
            for word in ${words[*]:1}; do
                case "$word" in
                --install|-*([a-zA-Z])i*([a-zA-Z]))
                    command_options=(
                        ${nix_env_common_opts[*]}
                        ${nix_env_b[*]} $nix_env_from_profile
                        '(--preserve-installed|-P)'{--preserve-installed,-P}
                        '(--remove-all|-r)'{--remove-all,-r}
                        '(-A|--attr)'{-A,--attr}
                        ':*->installed_packages')

                    break
                    ;;
                --upgrade|-*([a-zA-Z])u*([a-zA-Z]))
                    command_options=(
                        ${nix_env_common_opts[*]}
                        ${nix_env_b[*]}
                        ${nix_env_from_profile[*]}
                        '(-lt|-leq|-eq|--always)--lt'
                        '(-lt|-leq|-eq|--always)--leq'
                        '(-lt|-leq|-eq|--always)--eq'
                        '(-lt|-leq|-eq|--always)--always'
                        ':*->installed_packages')
                    break
                    ;;
                --uninstall|-*([a-zA-Z])e*([a-zA-Z]))
                    command_options=(${nix_env_common_opts[*]}
                                     ':*->installed_packages')
                    break
                    ;;
                --set-flag)
                    command_options=(${nix_env_common_opts[*]})
                    break
                    ;;
                --query|-*([a-zA-Z])q*([a-zA-Z]))
                    command_options=(
                        ${nix_env_common_opts[*]}
                        ${nix_env_b[*]}
                        '(--available|-a)'{--available,-a}
                        '(--status|-s)'{--status,-s}
                        '(--attr-path|-P)'{--attr-path,-P}
                        '(--compare-versions|-c)'{--compare-versions,-c}
                        '--no-name' '--system' '--drv-path' '--out-path'
                        '--description' '--xml' '--json' '--meta')
                    break
                    ;;
                    --switch-profile|-*([a-zA-Z])S*([a-zA-Z]))
                        command_options=(${nix_env_common_opts[*]}
                                         ':->profile')
                        break
                        ;;
                    --delete-generations)
                        command_options=(${nix_env_common_opts[*]}
                                         ':*->nix_generation')
                        break
                        ;;
                    --switch-generation|-*([a-zA-Z])G*([a-zA-Z]))
                        command_options=(${nix_env_common_opts[*]}
                                         ':->nix_generation')
                        break
                        ;;
                    --list-generations)
                        command_options=(${nix_env_common_opts[*]})
                        break
                        ;;
                esac
            done

            _parse ${command_options[*]} \
                   '*'{--file,-f}':->option-FILE' \
                   ${nix_boilerplate_opts} ${main_spec[*]} && return 0

            case "$state" in
                installed_packages)
                    if [[ (${opts[-i]} || ${opts[--install]}) \
                       && (${opts[-A]} || ${opts[--attr]}) ]]; then
                        # -iA means we should complete attribute paths
                        state=attr_path
                    elif [[ "$cur" == @("./"*|/*|\~*) ]]; then
                        # Complete files and return if we're entering files with
                        # absolute file syntax that nix will understand
                        state=file
                    else
                        local -a packages=($(nix-env -q))
                        packages=(${packages[*]%%-[0-9]*})
                        COMPREPLY=($(compgen -W "${packages[*]}" -- "$cur"))
                        return
                    fi
                    ;;
                nix_generation)
                    local -a generations=($(nix-env --list-generations | \
                          sed -E \
                              -e 's=  ([0-9]+)  .*=\1='))
                    COMPREPLY=($(compgen -W "${generations[*]}" -- "$cur"))
                    return
                    ;;
                flag_name)
                    COMPREPLY=($(compgen -W "priority keep active" -- "$cur"))
                    return
                    ;;
                flag_value)
                    local flag_name=$prev
                    case $flag_name in
                        priority)
                            return 0
                            ;;
                        keep|active)
                            COMPREPLY=($(compgen -W "true false" -- "$cur"))
                            return 0
                            ;;
                    esac
                    ;;
            esac
            ;;
        nix-store)
            local -a main_options=(
                {--realise,-r} '--gc' '--delete' {--query,-q} '--add'
                '--verify' '--verify-path' '--repair-path' '--dump'
                '--restore' '--export' '--import' '--optimise'
                {--read-log,-l} '--dump-db' '--load-db' '--print-env'
                '--query-failed-paths' '--clear-failed-paths')
            local ex_group="${main_options[*]}"
            ex_group="(${ex_group// /|})"
            local -a main_spec=(${main_options[*]/#/$ex_group})

            local -a command_options=()
            for word in ${words[*]:1}; do
                case "$word" in
                    --realise|-*([a-zA-Z])r*([a-zA-Z]))
                        command_options=(
                            ${nix_dry_run[*]}
                            '--add-root:->gc-root' '--indirect'
                            '--ignore-unknown'
                            ':*->file')
                        break
                        ;;
                    --gc)
                        command_options=(
                            ${nix_gc_common[*]}
                            '--max-freed:->empty')
                        break
                        ;;
                    --delete)
                        command_options=('--ignore-liveness'
                                        ':*->file')
                        break
                        ;;
                    --query|-*([a-zA-Z])q*([a-zA-Z]))
                        local -a queries=(
                            '--outputs' {--requisites,-R} '--references'
                            '--referrers' '--referrers-closure'
                            '--deriver' '--graph' '--tree' '--binding'
                            '--hash' '--size' '--roots')
                        local query_group="${queries[*]}"
                        query_group="(${query_group// /|})"
                        local -a query_spec=(${queries[*]/#/$query_group})

                        local -a query_common=(
                            '(--use-output|-u)'{--use-output,-u}
                            '(--force-realise|-f)'{--force-realise,-f})

                        local -a requisite_options=()
                        for opt in ${words[*]:1}; do
                            case "$opt" in
                                --requisites|-*([a-zA-Z])R*([a-zA-Z]))
                                    requisite_options=('--include-outputs')
                                    ;;
                            esac
                        done
                        command_options=(${query_spec[*]} ${query_common[*]}
                                         {requisite_options[*]} ":*->file")
                        break
                        ;;
                    --verify)
                        command_options=('--check-contents' '--repair')
                        break
                        ;;
                    --dump-db|--load-db|--query-failed-paths)
                        # Nothing to complete
                        break
                        ;;
                    *)
                        command_options=(':*->file')
                        break
                        ;;
                esac
            done

            _parse ${nix_boilerplate_opts[*]} ${command_options[*]} \
                   ${nix_new_opts[*]} \
                   ${main_spec[*]} && return 0
            ;;
        nix-channel)
            # nix-channel handling
            _parse \
                ${nix_boilerplate_opts[*]} \
                ${nix_new_opts[*]} \
                '(-*)--add:->url:->channel_name' \
                '(-*)--remove:->nix_channels' \
                '(-*)--list' \
                '(-*)--update:->nix_channels'\
                '(-*)--rollback' && return 0

            case "$state" in
                nix_channels)
                    channels=($(nix-channel --list \
                                    | sed -E \
                                          -e 's/ .*//'))
                    COMPREPLY=($(compgen -W "${channels[*]}" -- "$cur"))
                    return 0
                    ;;
            esac
            ;;
        nix-copy-closure)
            _parse \
                ${nix_boilerplate_opts[*]} \
                ${nix_new_opts[*]} \
                '(--from)--to' '(--to)--from' '--sign' '--gzip' \
                '--include-outputs' '(--use-substitutes -s)'{--use-substitutes,-s} \
                ':_user_at_host' ':*->file' && return 0
            ;;
        nix-collect-garbage)
            _parse \
                ${nix_boilerplate_opts[*]} \
                ${nix_new_opts[*]} \
                '(--delete-old|-d)'{--delete-old,-d} \
                '--delete-older-than:->empty' \
                ${nix_dry_run[*]} && return 0
            ;;
        nix-hash)
            local ig='--to-base16|--to-base32'
            _parse \
                ${nix_boilerplate_opts[*]} \
                ${nix_new_opts[*]} \
                '(-*)--to-base16:->hash' \
                '(-*)--to-base32:->hash' \
                "($ig)--flat" \
                "($ig)--base32" \
                "($ig)--truncate" \
                "($ig)--type:->option-TYPE" \
                ":*->file" && return 0

            # TODO: Don't add file completion if we're using anything in $ig
            ;;
        nix-instantiate)
            _parse \
                ${nix_boilerplate_opts[*]} '(--expr|-E)'{--expr,-E} \
                ${nix_common_opts[*]} '--xml' '--json' '--add-root:->gc-root' \
                '--indirect' '--parse' '--eval' "(-*)--find-file:*->nix-path-file"\
                '--strict' '--read-write-mode' ':*->file-or-expr' && return 0
            ;;
        nix-install-package)
            _parse \
                ${nix_boilerplate_opts[*]} \
                '--non-interactive' \
                '(--profile|-p)'{--profile,-p}':->nix_profile' \
                '--set' \
                '--url:->url' \
                ':->file' && return 0
            # TODO: make --url and :->file mutually exclusive
            ;;
        nix-prefetch-url)
            _parse '--type:->option-TYPE' ':->option-FILE' ':->empty'\
                   '*'{--attr,-A}':->attr_path' '--unpack' \
                   '--name:->store-name' '--print-path' \
                && return 0
            ;;
        nix-push)
            _parse \
                ${nix_boilerplate_opts[*]} \
                '--dest:->directory' '(--none)--bzip2'\
                '(--bzip2)--none' '--force' '--link'\
                '(--manifest-path)--manifest'\
                '(--manifest)--manifest-path:->file'\
                '--url-prefix:->url'\
                ':*->file' && return 0
            ;;
        nixos-option)
            _parse \
                $nix_search_path_args '--xml' \
                ':->nixos_options' && return 0

            if [[ "$state" == nixos_options ]]; then
                _nix_attr_paths '
                with import <nixpkgs/lib>;
                filterAttrsRecursive
                  (k: _: substring 0 1 k != "_")
                  (evalModules { modules = import <nixpkgs/nixos/modules/module-list.nix>; }).options
                '
                return 0
            fi

            ;;
        nixos-rebuild)
            main_commands=(
                'switch' 'boot' 'test' 'build' 'dry-build'
                'dry-activate' 'edit' 'build-vm' 'build-vm-with-bootloader')
            _parse \
                ${nix_boilerplate_opts[*]} \
                ${nix_common_nixos_rebuild[*]} \
                "*--option:->nixoption:->nixoptionvalue" \
                '--upgrade' '--install-grub' "--no-build-nix"             \
                '--fast' '--rollback'                                     \
                '(--profile-name|-p)'{--profile-name,-p}':->profile-name'  \
                ':->main_command' && return 0
            ;;
        nixos-install)
            _parse \
                ${nix_boilerplate_opts[*]} \
                $nix_search_path_args '--root:->directory'\
                '--show-trace' '--chroot' && return 0
            ;;
        nixos-generate-config)
            _parse ${nix_boilerplate_opts[*]} \
                   '--no-filesystems' '--show-hardware-config' '--force'\
                   '--root:->directory' '--dir:->directory' && return 0
            ;;
        nixos-version)
            _parse ${nix_boilerplate_opts[*]} \
                   '(-*)'{--hash,--revision} && return 0
            ;;
        nixos-container)
            main_commands=(
                'list' 'create' 'destroy' 'start' 'stop' 'status' 'update'
                'login' 'root-login' 'run' 'show-ip' 'show-host-key')

            local container_name=':->container';
            local container_config='--config:->container_config';
            local -a main_options=()
            for word in ${words[*]:1}; do
                case "$word" in
                    create)
                        main_options=(
                            $container_name $container_config '--config-file:->file'
                            '--system-path:->file' '--ensure-unique-name'
                            '--auto-start')
                        break
                        ;;
                    run)
                        main_options=($container_name)
                        break
                        ;;
                    update)
                        main_options=($container_name $container_config)
                        break
                        ;;
                    destroy|start|stop|status|login|root-login|show-ip|show-host-key)
                        main_options=($container_name)
                        break
                        ;;
                esac
            done
            _parse '--help' ':->main_command' ${main_options[*]} && return 0
            case "$state" in
                container)
                    local -a containers=($(nixos-container list))
                    COMPREPLY=($(compgen -W "${containers[*]}" -- "$cur"))
                    return 0
                    ;;
            esac
            ;;
       nixos-build-vms)
           _parse '--show-trace' "--no-out-link" \
                  ':->nix_file' '--help'\
               && return 0
           ;;

       nixops)
           main_commands=(
               list create modify clone delete info check set-args deploy
               send-keys destroy stop start reboot show-physical ssh
               ssh-for-each scp rename backup backup-status remove-backup
               clean-backups restore show-option list-generations rollback
               delete-generation show-console-output dump-nix-paths export
               import edit)

           # Options valid for every command
           local -a nixops_common_arguments=(
               '(--state|-s)'{--state,-s}':->file'
               '(--deployment|-d)'{--deployment,-d}
               '--confirm' '--debug')
           local -a nixops_include_exclude=(
               '--include:_known_hosts' '--exclude:_known_hosts')
           local -a nixops_search_path_args=('-I:->option-INCLUDE')


           local -a command_options=()
           for word in ${words[*]:1}; do
               case "$word" in
                   create)
                       main_options=(
                           ${nixops_search_path_args[*]}
                           ':*->nix_file')
                       break
                       ;;
                   modify)
                       main_options=(
                           ${nixops_search_path_args[*]}
                           '(--name|-n)'{--name,-n}':->empty'
                           ':*->nix_file')
                       break
                       ;;
                   clone)
                       main_options=('(--name|-n)'{--name,-n}':->empty')
                       break
                       ;;
                   delete)
                       main_options=('--all' '--force')
                       break
                       ;;
                   deploy)
                       main_options=(
                           '(--kill-obsolete|-k)'{--kill-obsolete,-k}
                           ${nix_dry_run[*]} ${nix_repair[*]}
                           '--create-only' '--build-only' '--copy-only' '--check'
                           '--allow-reboot' '--force-reboot' '--allow-recreate'
                           ${nixops_include_exclude[*]}
                           ${nixops_search_path_args[*]}
                           '--max-concurrent-copy:->number')
                       break
                       ;;
                   destroy)
                       main_options=(
                           '--all'
                           ${nixops_include_exclude[*]})
                       break
                       ;;
                   stop|start|backp)
                       main_options=(${nixops_include_exclude[*]})
                       break
                       ;;
                   info)
                       main_options=('--all' '--plain' '--no-eval')
                       break
                       ;;
                   check|ssh)
                       break
                       ;;
                   ssh-for-each)
                       main_options=(
                           '(--parallel|-p)'{--parallel,-p}
                           ${nixops_include_exclude[*]})
                       break
                       ;;
                   reboot)
                       main_options=(
                           ${nixops_include_exclude[*]} '--no-wait')
                       break
                       ;;
                   restore)
                       main_options=(
                           ${nixops_include_exclude[*]}
                           '--devices:->device_name'
                           '--backup-id:->backup_id')
                       break
                       ;;
                   show-option)
                       main_options=(
                           '--xml' ':_known_hosts' ':->nixops_option')
                       break
                       ;;
                   set-args)
                       main_options=(
                           '*--arg:->arg_name:->arg_value'
                           '*--argstring:->arg_name:->arg_value'
                           '--unset:->empty')
                       break
                       ;;
                   show-console-output)
                       main_options=(':_known_hosts')
                       break
                       ;;
                   export)
                       break
                       ;;
                   import)
                       main_options=(
                           '--include-keys')
                       break
                       ;;
               esac
           done

           _parse ':->main_command' \
                  ${nixops_common_arguments[*]} \
                  ${main_options[*]} \
                  ${nix_boilerplate_opts[*]} && return 0
           ;;
       nix)
           type nix &> /dev/null || return

           local -a common_options
           common_options=("(--debug)"--debug "(-h|--help)"{-h,--help}
                           "(--help-config)"--help-config
                           "*--builders:->machine" "--store:->option-STORE-URI"
                           "*--option:->nixoption:->nixoptionvalue"
                           "(--quiet)--quiet" "*{-v,--verbose}"
                           "(--version)"--version)

           # Extract the commands with descriptions
           # like ('command:some description' 'run:run some stuff')
           main_commands=(
               $(nix --help | sed -E \
                                  -e '/^Available commands/,/^$/!d' \
                                  -e '/^Available commands/d' \
                                  -e '/^$/d' \
                                  -e 's=^ +([0-9a-z-]*) +(.*)$=\1='))
           # Add commands to an associative array for easy lookup
           local -A command_lookup
           local main_command
           for main_command in ${main_commands[*]}; do
               command_lookup[$main_command]=1
           done

           local -a command_options=()
           local -a command_arguments=()
           # Setup the correct command_arguments and command_options depending
           # on which command we've typed
           local word
           for word in ${words[*]:1}; do

               # Check if we're in a valid command
               if [[ "${command_lookup[$word]}" == 1 ]]; then
                   # Extract an array describing the possible arguments to the
                   # command eg. (NAR PATH) for cat-nar or (INSTALLABLES) for
                   # run
                   local -a args=(
                       $(nix $word --help | sed -E \
                                                -e '2,$d' \
                                                -e 's=^Usage.*<FLAGS>==' \
                                                -e 's=\.|\?|<|>==g'))
                   # And add the corresponding completors
                   local arg
                   for arg in ${args[*]}; do
                       local plural=""
                       [[ "$arg" == *S ]] && plural="*"
                       command_arguments+=(":${plural}->arg-$arg")
                   done

                   # Extract the lines containing the option descriptions
                   # Strip out the human descriptions
                   local -a option_descriptions
                   option_descriptions=(
                       $(nix $word --help | sed -E \
                                                -e '/^Flags:/,/^$/!d' \
                                                -e "/^Flags:/d" \
                                                -e 's/(.*)  .*/\1/' \
                                                -e 's/ //g' \
                                                -e '/^$/d'))

                   local option option_spec
                   for option_spec in ${option_descriptions[*]}; do

                       # Extract the options by stripping everything up from the
                       # first '<', and any ','
                       local -a option_group=($(echo "$option_spec" \
                                                    | sed -E \
                                                          -e 's=,= =' \
                                                          -e 's=<.*=='))
                       # Extract any arguments, by stripping the options, and
                       # any '<' or '>'
                       local -a option_args=(
                           $(echo "$option_spec" \
                                 | sed -E \
                                       -e "s=.*${option_group[*]: -1}==" \
                                       -e 's=[^<]*<==' \
                                       -e 's=<|>= =g'))

                       local ACTIONS=""
                       for arg in ${option_args[*]}; do
                           local plural=""
                           [[ "$arg" == *S ]] && plural="*"
                           ACTIONS+=":${plural}->option-$arg"
                       done

                       for option in ${option_group[*]}; do
                           # Handle `run --keep/--unset` manually as they can be
                           # repeated
                           if [[ "$word" == run \
                              && "$option" == @(-k|--keep|-u|--unset) ]]; then
                               command_options+=("*${option}:->option-PARAMS")
                           elif [[ "$word" == add-to-store \
                                       && "$option" == @(-n|--name) ]]; then
                                # Another <NAME> ambiguity
                                local exclusions="${option_group[*]}"
                                command_options+=("(${exclusions// /|})${option}:->store-name")
                           elif [[ "$option" == @(-I|--include) ]]; then
                               # Special handling of --include due to type
                               # ambiguity
                               command_options+=("*${option}:->option-INCLUDE")
                           elif [[ "$option" == @(--arg|--argstr|-f|--file) ]]; then
                               # Repeatable options
                               command_options+=("*${option}"$ACTIONS)
                           else
                               # Default to mutually exclusive non-repeatable
                               # options
                               local exclusions="${option_group[*]}"
                               command_options+=("(${exclusions// /|})"$option$ACTIONS)
                           fi
                       done
                   done

                   break
               fi
           done

           _nix_print "command arguments: "

           _parse ':->main_command' \
                  ${command_arguments[*]} \
                  ${common_options[*]} \
                  ${command_options[*]} && return 0
           ;;
    esac

    _nix_print  "state: $state"
    _nix_print  "line: ${line[*]}"
    _nix_print  "opt_args: ${!opt_args[*]} ${opt_args[*]}"

    # Handle completion of different types of arguments
    while true; do
    case "$state" in
        main_command)
            COMPREPLY=($(compgen -W "${main_commands[*]}" -- "$cur"))
            return
            ;;
        arg-@(INSTALLABLES|INSTALLABLE|PACKAGE|DEPENDENCY))
            if [[ "$cur" == @("./"*|/*|\~*) ]]; then
                # Complete files and return if we're entering files with
                # absolute file syntax that nix will understand
                compopt -o nospace
                COMPREPLY=($(compgen -f -- $cur))
                return 0
            fi
            # Continue with the shared attr_path handling
            ;&
        attr_path)
            # Handle all the various way commands expects the top level
            # expression being built

            local defexpr=""
            local file=$(_nix_get_file_arg)
            if [[ "$file" ]]; then
                # Extract --arg and --argstr into $args
                local i=1 args="" name="" value=""
                for ((i=1; i < ${#words[*]}; i++)); do
                    case "${words[$i]}" in
                        --arg)
                            name=$(dequote "${words[$((i+1))]}")
                            value=$(dequote "${words[$((i+2))]}")
                            args+="$name = $value;"
                            i=$((i+2))
                            ;;
                        --argstr)
                            name=$(dequote "${words[$((i+1))]}")
                            value=$(dequote "${words[$((i+2))]}")
                            args+="$name = \"$value\";"
                            i=$((i+2))
                            ;;
                    esac
                done
                args=${args:+\{$args\}}

                if [[ "${opts[--expr]}" || "${opts[-E]}" ]]; then
                    defexpr="($file) $args"
                else
                    defexpr="import $file $args"
                fi
            else
            # If there's no file input, generate the default top level
            # expressions for nix-env or nix
                if [[ "${words[0]}" == nix-env ]]; then
                    # Generate nix code creating the default expression used by
                    # 'nix-env -iA'
                    local -a result
                    local -a queue=(~/.nix-defexpr)
                    while [[ ${#queue[*]} > 0 ]]; do
                        local current="${queue[0]}"
                        queue=(${queue[*]:1})
                        if [[ -e "$current/default.nix" ]]; then
                            result+=($current)
                        else
                            local -a children=($(echo "$current"/*))
                            if [[ "$children" != *\* ]]; then
                                queue+=(${children[*]})
                            fi
                        fi
                    done

                    defexpr="{ "
                    for p in ${result[*]}; do
                        defexpr+="$(basename $p) = import $p; "
                    done
                    defexpr+="}"

                elif [[ "${words[0]}" == nix ]]; then
                    # Fall back to completing available channels in the NIX_PATH

                    # Extract the channels from NIX_PATH and -I/--include
                    local -a channels=(${NIX_PATH[*]//:/ })
                    # The order doesn't matter as we're only using the names
                    # This will also split eg. htttp://some/path, but we'll we'll
                    # throw those elements away since they don't contain a '='
                    channels+=(${opt_args[-I]//:/ })
                    channels+=(${opt_args[--include]//:/ })

                    # Add the names in an associative array to avoid duplicates
                    local -A names
                    local channel name
                    for channel in ${channels[*]}; do
                        name=${channel%%=*}
                        if [[ "$name" != "$channel" ]]; then
                            # Only add paths with a name, not sure how they work
                            names[$name]=1
                        fi
                    done

                    defexpr=$'{ '
                    for name in ${!names[*]}; do
                        # nixos-config isn't useful or possible to complete
                        [[ "$name" == nixos-config ]] && continue
                        defexpr+="$name = import <${name}>; "
                    done
                    defexpr+=' }'
                fi
            fi

            _nix_print defexpr: "$defexpr"
            _nix_attr_paths "$defexpr"
            return 0
            ;;
        function-arg|option-NAME)
            local file=$(_nix_get_file_arg)
            local func=""
            if [[ "${opts[--expr]}" || "${opts[-E]}" ]]; then
                func="$file"
            else
                func="import $file"
            fi
            local i exclude=""
            for ((i=1; i < ${#words[*]}; i++)); do
                case "${words[$i]}" in
                    --arg|--argstr)
                        # Don't add the name we're currently typing
                        [[ $i == $((cword - 1)) ]] && continue
                        exclude+=${exclude:+|}${words[$((i+1))]}
                        ;;
                esac
            done
            local -a names=($(_nix_eval_stdin <<NIX_FILE
                  let
                    args = builtins.functionArgs ($func);
                  in
                    builtins.attrNames args
NIX_FILE
                              ))
            COMPREPLY=($(compgen -W "${names[*]}" -X "*($exclude)" -- "$cur"))
            return
            ;;
        file-or-expr)
            if [[ "${opts[--expr]}" || "${opts[-E]}" ]]; then
                state=expr
            else
                state=option-FILE
            fi
            continue
            ;;
        profile|option-PROFILE-DIR)
            compopt -o filenames
            if [[ "$cur" ]]; then
                COMPREPLY=($(compgen -d -- "$cur"))
            else
                local profiles=/nix/var/nix/profiles/
                COMPREPLY=($(cd $profiles && compgen -P $profiles -d \
                                                     -- "${cur#$profiles}"))
            fi
            return
            ;;
        gc-root)
            compopt -o filenames
            if [[ "$cur" || "${opts[--indirect]}" ]]; then
               COMPREPLY=($(compgen -d -- $cur))
            else
                local gcroot=/nix/var/nix/gcroots/
                COMPREPLY=($(cd $gcroot && compgen -P $gcroot -d \
                                                   -- ${cur#$gcroot}))
            fi
            return
            ;;
        nix-system)
            local -a systems=(
                $(_nix_eval_stdin <<NIX_FILE
                                  (import <nixpkgs> {}).lib.systems.doubles.all
NIX_FILE
                ))
            COMPREPLY=($(compgen -W "${systems[*]}" -- "$cur"))
            return
            ;;
        arg-@(PATH|PATHS|NAR))
            compopt -o filenames
            COMPREPLY=($(compgen -f -- $cur))
            return
            ;;
        option-STORE-URI|directory)
            ## Not sure how to present alternatives here
            compopt -o filenames
            COMPREPLY=($(compgen -d -- $cur))
            return
            ;;
        option-COMMAND)
            COMPREPLY=($(compgen -c -- $cur))
            return
            ;;
        option-FILE|arg-FILES)
            if [[ "$cur" == channel:* ]]; then
                local -a channels=(
                    nixos-13.10           nixos-16.09
                    nixos-14.04           nixos-16.09-small
                    nixos-14.04-small     nixos-17.03
                    nixos-14.12           nixos-17.03-small
                    nixos-14.12-small     nixos-17.09
                    nixos-15.09           nixos-17.09-small
                    nixos-15.09-small     nixos-unstable
                    nixos-16.03           nixos-unstable-small
                    nixos-16.03-small     nixpkgs-17.09-darwin
                    nixos-16.03-testing   nixpkgs-unstable
                    nixpkgs-18.03-darwin  nixos-18.03
                    nixos-18.03-small
                )
                COMPREPLY=($(compgen -W "${channels[*]}" -- "${cur#*:}"))
                return
            fi
            ;&
        arg-FILES|nix_file)
            compopt -o filenames
            COMPREPLY=($(compgen -d -- "$cur"))
            COMPREPLY+=($(compgen -X "!*.nix" -f -- "$cur"))
            return
            ;;
        option-FILES|option-PATH|file)
            compopt -o filenames
            COMPREPLY=($(compgen -f -- $cur))
            return
            ;;
        option-TYPE)
            COMPREPLY=($(compgen -W "md5 sha1 sha256 sha512" -- "$cur"))
            return
            ;;
        option-PARAMS)
            COMPREPLY=($(compgen -v -- $cur))
            return
            ;;
        option-INCLUDE)
            # --include <PATH> completion
            case "$cur" in
                /*|./*|~/*)
                    compopt -o filenames
                    COMPREPLY=($(compgen -d -- "$cur"))
                    COMPREPLY+=($(compgen -X "!*.nix" -f -- "$cur"))
                    ;;
                *=*)
                    # This actually works due to bash's COMP_WORDBREAKS
                    # weirdness
                    compopt -o filenames
                    COMPREPLY=($(compgen -d -- "${cur#*=}"))
                    COMPREPLY+=($(compgen -X "!*.nix" -f -- "${cur#*=}"))
                    ;;
                *)
                    local -a nixpath=(${NIX_PATH//:/ })
                    local -a path_names
                    local p
                    for p in ${nixpath[*]}; do
                        [[ "$p" == *=* ]] && path_names+=(${p%=*})
                    done
                    compopt -o nospace
                    COMPREPLY=($(compgen -S "=" -W "${path_names[*]}" -- "$cur"))
                    ;;
            esac
            return
            ;;
        nixoption)
            local -a nix_options
            nix_options=($(nix --help-config | sed -E \
                                                   -e '/^$/,/^$/!d' \
                                                   -e '/^$/d' \
                                                   -e 's=^ +([0-9a-z-]*) +(.*)$=\1='))
            COMPREPLY=($(compgen -W "${nix_options[*]}" -- $cur))
            return
            ;;
        *|arg-REGEX|arg-STRINGS|option-NAME|option-EXPR|option-STRING)
            _nix_print  "$state not implemented yet"
            # Fall back to file completion
            compopt -o filenames
            COMPREPLY+=($(compgen -f -- "$cur"))
            return
            ;;

    esac
    done
    return 1
}
# Set up the completion for all relevant commands
complete -F _nix_completion \
          nix-build nix-shell nix-env nix-store \
          nix-channel nix-copy-closure nix-collect-garbage \
          nix-hash nix-instantiate \
          nix-install-package nix-prefetch-url nix-push \
          nixos-install nixos-version \
          nixos-container nixos-generate-config nixos-build-vms \
          nixos-option
