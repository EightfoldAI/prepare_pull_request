#!/bin/bash
# Varun Chopra <vchopra@eightfold.ai>
#
# This action runs every time a PR is updated & prepares it for CI.
# CI checks pull requests that are labeled 'needs_ci' and runs unit tests and lint.

set -e

if [[ -z "$GITHUB_TOKEN" ]]; then
  echo "Set the GITHUB_TOKEN env variable."
  exit 1
fi

if [[ -z "$GITHUB_REPOSITORY" ]]; then
  echo "Set the GITHUB_REPOSITORY env variable."
  exit 1
fi

if [[ -z "$GITHUB_EVENT_PATH" ]]; then
  echo "Set the GITHUB_EVENT_PATH env variable."
  exit 1
fi

URI="https://api.github.com"
API_HEADER="Accept: application/vnd.github.v3+json"
AUTH_HEADER="Authorization: token ${GITHUB_TOKEN}"

action=$(jq --raw-output .action "$GITHUB_EVENT_PATH")
pr_body=$(jq --raw-output .pull_request.body "$GITHUB_EVENT_PATH")
number=$(jq --raw-output .pull_request.number "$GITHUB_EVENT_PATH")
title=$(jq --raw-output .pull_request.title "$GITHUB_EVENT_PATH")
draft=$(jq --raw-output .pull_request.draft "$GITHUB_EVENT_PATH")

echo $title
echo $draft

has_hotfix_label=false
hotfix_failed=false

if [[ "$draft" == "true" ]]; then
  echo "Skipping PR since it's still in draft."
  exit 0
fi
if [[ "$title" =~ ^HOTFIX.*$ ]]; then
  needs_hotfix=true
fi

add_comment(){
  curl -sSL \
    -H "${AUTH_HEADER}" \
    -H "${API_HEADER}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{\"body\":\"${1}\"}" \
    "${URI}/repos/${GITHUB_REPOSITORY}/issues/${number}/comments"
}

add_label(){
  curl -sSL \
    -H "${AUTH_HEADER}" \
    -H "${API_HEADER}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{\"labels\":[\"${1}\"]}" \
    "${URI}/repos/${GITHUB_REPOSITORY}/issues/${number}/labels"
}

remove_label(){
  curl -sSL \
    -H "${AUTH_HEADER}" \
    -H "${API_HEADER}" \
    -X DELETE \
    "${URI}/repos/${GITHUB_REPOSITORY}/issues/${number}/labels/${1// /%20}"
}

body=$(curl -sSL -H "${AUTH_HEADER}" -H "${API_HEADER}" "${URI}/repos/${GITHUB_REPOSITORY}/pulls/${number}")

labels=$(echo "$body" | jq --raw-output '.labels[].name')

IFS=$'\n'

for label in $labels; do
  case $label in
    ci_verified)
      echo "Removing label: $label"
      remove_label "$label"
      ;;
    ci_verified:lite)
      echo "Removing label: $label"
      remove_label "$label"
      ;;
    needs_ci)
      echo "Removing label: $label"
      remove_label "$label"
      ;;
    needs_hotfix)
      echo "Setting has_hotfix_label=true"
      has_hotfix_label=true
      ;;
    "hotfix:failed")
      echo "Setting hotfix_failed=true"
      hotfix_failed=true
      ;;
    *)
      echo "Unknown label $label"
      ;;
  esac
done

add_label "needs_ci:lite"

if [[ ("$needs_hotfix" = true && "$has_hotfix_label" = false && "$hotfix_failed" = false) ]]; then
  echo "Detected HOTFIX pull request that isn't already labeled."
  add_label "needs_hotfix"
fi

echo "Pull request passed all checkpoints!"
