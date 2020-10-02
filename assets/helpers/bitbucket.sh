#!/bin/bash

set -e

ASSETS=$(cd "$(dirname "$0")" && pwd)
source $ASSETS/helpers/utils.sh

VALUES_LIMIT=100

bitbucket_request() {
  # $1: host
  # $2: path
  # $3: query
  # $4: data
  # $5: url base path
  # $6: Skip SSL verification
  # $7: netrc file (default: $HOME/.netrc)
  # $8: HTTP method (default: POST for data, GET without data)
  # $9: recursive data for bitbucket paging
  # $10: expect plain text response
  local data="$4"
  local path=${5:-api/2.0}
  local skip_ssl_verification=${6:-"false"}
  local netrc_file=${7:-$HOME/.netrc}
  local method="$8"
  local recursive=${9:-limit=${VALUES_LIMIT}}
  local expect_plain_text=${10:-"false"}

  local request_url="${1}/${path}/${2}?${recursive}&${3}"
  local request_result=$(tmp_file_unique bitbucket-request)
  local request_data=$(tmp_file_unique bitbucket-request-data)

  # deletes the temp files
  request_result_cleanup() {
    rm -f "$request_result"
    rm -f "$request_data"
  }

  # register the cleanup function to be called on the EXIT signal
  trap request_result_cleanup EXIT

  local extra_options=""
  if [ -n "$data" ]; then
    method=${method:-POST}
    jq '.' <<< "$data" > "$request_data"
    extra_options="-H \"Content-Type: application/json\" -d @\"$request_data\""
  fi

  if [ -n "$method" ]; then
    extra_options+=" -X $method"
  fi

  if [ "$skip_ssl_verification" = "true" ]; then
    extra_options+=" -k"
  fi

  curl_cmd="curl -s --netrc-file \"$netrc_file\" $TOKEN $extra_options \"$request_url\" > \"$request_result\""
  if ! eval $curl_cmd; then
    log "Bitbucket request $request_url failed"
    exit 1
  fi

  if [ "$expect_plain_text" = "true" ]; then
    cat $request_result
    return
  fi

  if ! jq -c '.' < "$request_result" > /dev/null 2> /dev/null; then
    log "Bitbucket request $request_url failed (invalid JSON): $(cat "$request_result")"
    exit 1
  fi

  if [ "$(jq -r '.isLastPage' < "$request_result")" == "false" ]; then
    local nextPage=$(jq -r '.nextPageStart' < "$request_result")
    local nextResult=$(bitbucket_request "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "start=${nextPage}&limit=${VALUES_LIMIT}")
    jq -c '.values' < "$request_result" | jq -c ". + $nextResult"
  elif [ "$(jq -c '.values' < "$request_result")" != "null" ]; then
    jq -c '.values' < "$request_result"
  elif [ "$(jq -c '.error' < "$request_result")" == "null" ]; then
    jq '.' < "$request_result"
  elif [ "${request_result/NoSuchPullRequestException}" = "${request_result}" ]; then
    printf "ERROR"
    return
  else
    log "Bitbucket request ($request_url) failed: $(cat $request_result)"
    exit 1
  fi

  # cleanup
  request_result_cleanup
}

bitbucket_pullrequest() {
  # $1: host
  # $2: project
  # $3: repository id
  # $4: pullrequest id
  # $5: netrc file (default: $HOME/.netrc)
  # $6: skip ssl verification
  log "Retrieving pull request #$4 for $2/$3"
  bitbucket_request "$1" "repositories/$2/$3/pullrequests/$4" "" "" "" "$6" "$5"
}

bitbucket_pullrequests() {
  # $1: host
  # $2: project
  # $3: repository id
  # $4: netrc file (default: $HOME/.netrc)
  # $5: skip ssl verification
  log "Retrieving all open pull requests for $2/$3"
  bitbucket_request "$1" "repositories/$2/$3/pullrequests" "" "" "" "$5" "$4"
}

bitbucket_pullrequest_diff() {
  # $1: host
  # $2: project
  # $3: repository id
  # $4: from sha
  # $5: to sha
  # $6: netrc file (default: $HOME/.netrc)
  # $7: skip ssl verification
  log "Retrieving pull request diff status for $2/$3"
  bitbucket_request "$1" "repositories/$2/$3/diff/$4..$5" "" "" "" "$7" "$6" "" "" "true"
}

bitbucket_pullrequest_overview_comments() {
  # $1: host
  # $2: project
  # $3: repository id
  # $4: pullrequest id
  # $5: netrc file (default: $HOME/.netrc)
  # $6: skip ssl verification

  log "Retrieving pull request comments #$4 for $2/$3"
  set -o pipefail; bitbucket_request "$1" "repositories/$2/$3/pullrequests/$4/comments" "" "" "" "$6" "$5" | \
    jq 'map(select(.deleted == false)) | sort_by(.created_on) | reverse | map({ id: .id, text: .content.raw, createdDate: .created_on })'
}

bitbucket_pullrequest_progress_msg_start() {
  # $1: pull request hash
  # $2: type
  local hash="$1"
  local type="$2"

  local build_url_job="$ATC_EXTERNAL_URL/teams/$(rawurlencode "$BUILD_TEAM_NAME")/pipelines/$(rawurlencode "$BUILD_PIPELINE_NAME")/jobs/$(rawurlencode "$BUILD_JOB_NAME")"
  echo "**Build$type** at **[${BUILD_PIPELINE_NAME} > ${BUILD_JOB_NAME}]($build_url_job)** for $hash"
}

bitbucket_pullrequest_progress_commit_match() {
  # $1: pull request comment
  # $2: pull request hash
  # $3: type of build to match
  local comment="$1"
  local hash="$2"
  local type="$3"

  local msg=$(bitbucket_pullrequest_progress_msg_start "$hash" "$type")
  echo "$comment" | grep -Ec "^$(regex_escape "$msg")" > /dev/null
}

bitbucket_pullrequest_comment_commit_match() {
  # $1: pull request comment
  # $2: pull request hash
  local comment="$1"
  local hash="$2"

  local msg=")** for $hash into"
  echo "$comment" | grep -Ec "$(regex_escape "$msg")" > /dev/null
}

bitbucket_pullrequest_progress_comment() {
  # $1: status (success, failure or pending)
  # $2: hash of source commit
  # $3: hash of target commit
  # $4: custom comment

  local progress_msg_end=""
  local custom_comment=""

  progress_msg_end="$2 into $3"

  if [ -n "$4" ]; then
    custom_comment="\n\n$5"
  fi

  local build_url="$ATC_EXTERNAL_URL/teams/$(rawurlencode "$BUILD_TEAM_NAME")/pipelines/$(rawurlencode "$BUILD_PIPELINE_NAME")/jobs/$(rawurlencode "$BUILD_JOB_NAME")/builds/$(rawurlencode "$BUILD_NAME")"
  local build_result_pre=" \n\n **["
  local build_result_post="]($build_url)** - Build #$BUILD_NAME"

  case "$1" in
    success)
      echo "$(bitbucket_pullrequest_progress_msg_start "$hash" "Finished")${progress_msg_end}${build_result_pre}✓ BUILD SUCCESS${build_result_post}${custom_comment}" ;;
    failure)
      echo "$(bitbucket_pullrequest_progress_msg_start "$hash" "Finished")${progress_msg_end}${build_result_pre}✕ BUILD FAILED${build_result_post}${custom_comment}" ;;
    pending)
      echo "$(bitbucket_pullrequest_progress_msg_start "$hash" "Started")${progress_msg_end}${build_result_pre}⏳ BUILD IN PROGRESS${build_result_post}${custom_comment}" ;;
  esac
}

bitbucket_pullrequest_commit_status() {
  # $1: host
  # $2: project
  # $3: repository id
  # $4: commit
  # $5: data
  # $6: netrc file (default: $HOME/.netrc)
  # $7: skip ssl verification
  log "Setting pull request status $2/$3"
  bitbucket_request "$1" "repositories/$2/$3/commit/$4/statuses/build" "" "$5" "" "$7" "$6"
}

bitbucket_pullrequest_add_comment_status() {
  # $1: host
  # $2: project
  # $3: repository id
  # $4: pullrequest id
  # $5: comment
  # $6: netrc file (default: $HOME/.netrc)
  # $7: skip ssl verification
  log "Adding pull request comment for status on #$4 for $2/$3"
  bitbucket_request "$1" "repositories/$2/$3/pullrequests/$4/comments" "" "{\"content\":{\"raw\":\"$5\"}}" "" "$7" "$6"
}

bitbucket_pullrequest_update_comment_status() {
  # $1: host
  # $2: project
  # $3: repository id
  # $4: pullrequest id
  # $5: commentUpdating pull request comment (id: 180116834) for status on #5 for trolleksii/gitops
  # $6: comment id
  # $7: netrc file (default: $HOME/.netrc)
  # $8: skip ssl verification
  log "Updating pull request comment (id: $6) for status on #$4 for $2/$3"
  bitbucket_request "$1" "repositories/$2/$3/pullrequests/$4/comments/$6" "" "{\"content\":{\"raw\":\"$5\"}}" "" "$8" "$7" "PUT"
}

bitbucket_pull_request_activity() {
  # $1: host
  # $2: project
  # $3: repository id
  # $4: pullrequest id
  # $5: netrc file (default: $HOME/.netrc)
  # $6: skip ssl verification
  log "Retrieving pull request activity history #$4 for $2/$3"
  bitbucket_request "$1" "repositories/$2/$3/pullrequests/$4/activity" "" "" "" "$6" "$5"
}