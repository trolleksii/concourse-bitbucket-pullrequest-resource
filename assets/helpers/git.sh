load_pubkey() {
  local private_key_path=$TMPDIR/git-resource-private-key

  (jq -r '.source.private_key // empty' < $1) > $private_key_path

  if [ -s $private_key_path ]; then
    chmod 0600 $private_key_path

    eval $(ssh-agent) >/dev/null 2>&1
    trap "kill $SSH_AGENT_PID" 0

    SSH_ASKPASS=$ASSETS/helpers/askpass.sh DISPLAY= ssh-add $private_key_path >/dev/null

    mkdir -p ~/.ssh
    cat > ~/.ssh/config <<EOF
StrictHostKeyChecking no
LogLevel quiet
EOF
    chmod 0600 ~/.ssh/config
  fi
}

configure_git_global() {
  local git_config_payload="$1"
  eval $(echo "$git_config_payload" | \
    jq -r ".[] | \"git config --global '\\(.name)' '\\(.value)'; \"")
}

configure_git_ssl_verification() {
  if [ "$1" = "true" ]; then
    export GIT_SSL_NO_VERIFY=true
  fi
}

add_pullrequest_metadata_basic() {
  # $1: pull request number
  # $2: pull request repository
  local title=$(git config --get pullrequest.title)
  local commit=$(git config --get pullrequest.commit)
  local author=$(git log -1 --format=format:%an)

  jq \
    --arg id "$1" \
    --arg title "$title" \
    --arg author "$author" \
    --arg commit "$commit" \
    --arg repository "$2" \
    '. + [
      {name: "id", value: $id},
      {name: "title", value: $title},
      {name: "author", value: $author},
      {name: "commit (merged source in target)", value: $commit},
      {name: "repository", value: $repository}
    ]'
}

add_pullrequest_metadata_commit() {
  # $1: key for adding to metadata
  # $2: commit filter for git log
  local filter="$2 -1"

  local commit=$(git log $filter --format=format:%H)
  local author=$(git log $filter --format=format:%an)
  local author_date=$(git log $filter --format=format:%ai)
  local committer=$(git log $filter --format=format:%cn)
  local committer_date=$(git log $filter --format=format:%ci)
  local message=$(git log $filter --format=format:%B)

  local metadata="$(jq -n \
    --arg commit "$commit" \
    --arg author "$author" \
    --arg author_date "$author_date" \
    --arg message "$message" \
    '[
        {name: ($commit + " commit"), value: $commit },
        {name: ($commit + " author"), value: $author },
        {name: ($commit + " author_date"), value: $author_date, type: "time" },
        {name: ($commit + " message"), value: $message, type: "message" }
    ]'
  )"

  if [ "$author" != "$committer" ]; then
    metadata=$(jq --arg commit "$1" --arg value "${committer}" \
      '. + [{name: ($commit + " committer"), value: $value }]' <<< "$metadata")
  fi
  if [ "$author_date" != "$committer_date" ]; then
    metadata=$(jq --arg commit "$1" --arg value "${committer_date}" \
      '. + [{name: ($commit + " committer_date"), value: $value, type: "time" }]' <<< "$metadata")
  fi

  jq --argjson metadata "$metadata" '. + $metadata'
}

pullrequest_metadata() {
  # $1: pull request number
  # $2: pull request repository

  local source_commit=$(git rev-list --parents -1 $(git rev-parse HEAD) | awk '{print $3}')
  local target_commit=$(git rev-list --parents -1 $(git rev-parse HEAD) | awk '{print $2}')

  jq -n "[]" | \
    add_pullrequest_metadata_basic "$1" "$2" | \
    add_pullrequest_metadata_commit "source" "$source_commit" | \
    add_pullrequest_metadata_commit "target" "$target_commit"
}

configure_credentials() {
  local username=$(jq -r '.source.username // ""' < $1)
  local password=$(jq -r '.source.password // ""' < $1)

  rm -f $HOME/.netrc
  if [ "$username" != "" -a "$password" != "" ]; then
    echo "default login $username password $password" > $HOME/.netrc
  fi
}
