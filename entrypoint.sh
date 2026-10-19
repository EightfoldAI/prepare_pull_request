#!/bin/bash
# Varun Chopra <vchopra@eightfold.ai>
#
# This action runs every time a PR is updated & prepares it for CI.
# CI checks pull requests that are labeled 'needs_ci' and runs unit tests and lint.
# - If the 'needs_ci' label is present, no additional labels are added.
# - If the 'shipit' label is present, it ensures the 'needs_ci' label is added.
# - If neither 'needs_ci' nor 'shipit' are present, it adds the 'needs_ci:lite' label.
# - If 'ci_verified' label is present, it removes 'ci_verified' and adds 'needs_ci'.
# - If 'ci_verified:lite' label is present, it removes 'ci_verified:lite' and adds 'needs_ci:lite'.

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

# --- Which CI to request ---------------------------------------------------------------
# Two switches, "true" or "false", passed in by the calling workflow from repository
# variables:
#   CI_FLEET_TRIGGER  the fleet CI's labels: needs_ci, needs_ci:lite. Unset = true.
#   CI_K8S_TRIGGER    CI k8s's labels:       ci_k8s, ci_k8s:lite.     Unset = false.
fleet_on() { [[ "${CI_FLEET_TRIGGER:-true}" == "true" ]]; }
k8s_on() { [[ "${CI_K8S_TRIGGER:-false}" == "true" ]]; }

has_label() {  # has_label <name>: on the PR as this script read it
  local l
  for l in $labels; do [[ "$l" == "$1" ]] && return 0; done
  return 1
}

# A label added with GITHUB_TOKEN starts no workflow, so CI k8s is started with
# workflow_dispatch, which GITHUB_TOKEN may trigger (needs `actions: write`). Same-repo
# PRs only: a fork's code must not run on the CI cluster. Never fails the action.
same_repo_pr() {
  local head
  head=$(curl -sSL -H "${AUTH_HEADER}" -H "${API_HEADER}" \
    "${URI}/repos/${GITHUB_REPOSITORY}/pulls/${number}" | jq -r '.head.repo.full_name // ""') || return 1
  [[ "$head" == "$GITHUB_REPOSITORY" ]]
}

dispatch() {  # dispatch <workflow file> <inputs json>
  local ref
  ref=$(jq -r '.repository.default_branch // "master"' "$GITHUB_EVENT_PATH")
  curl -sSL -o /dev/null -w "dispatch $1: HTTP %{http_code}\n" \
    -H "${AUTH_HEADER}" -H "${API_HEADER}" -X POST -H "Content-Type: application/json" \
    -d "{\"ref\":\"${ref}\",\"inputs\":${2}}" \
    "${URI}/repos/${GITHUB_REPOSITORY}/actions/workflows/${1}/dispatches" || true
}

# k8s_request <label> <workflow file>: add a CI k8s request label and start its run,
# unless the PR already has it (a run is in flight; nothing to restart).
k8s_request() {
  k8s_on || return 0
  has_label "$1" && { echo "CI k8s: $1 already on"; return 0; }
  same_repo_pr || { echo "CI k8s: not a same-repo PR, skipping $1"; return 0; }
  add_label "$1" > /dev/null || true
  labels="${labels}"$'\n'"$1"
  dispatch "$2" "{\"pr\":\"${number}\"}"
}
# ----------------------------------------------------------------------------------------

action=$(jq --raw-output .action "$GITHUB_EVENT_PATH")
pr_body=$(jq --raw-output .pull_request.body "$GITHUB_EVENT_PATH")
number=$(jq --raw-output .pull_request.number "$GITHUB_EVENT_PATH")
title=$(jq --raw-output .pull_request.title "$GITHUB_EVENT_PATH")
draft=$(jq --raw-output .pull_request.draft "$GITHUB_EVENT_PATH")

echo $title
echo $draft

if [[ "$draft" == "true" ]]; then
  echo "Skipping PR since it's still in draft."
  exit 0
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

alternate_python_version=":3.13"
current_python_version=":3.13"
needs_ci_label_present=false
needs_ci_lite_label_present=false
shipit_label_present=false
alt_needs_ci_label_present=false
verified_full=false
verified_lite=false

for label in $labels; do
  case $label in
    ci_verified)
      echo "Removing label: $label and adding needs_ci"
      remove_label "$label"
      if fleet_on; then add_label "needs_ci"; fi
      needs_ci_label_present=true
      verified_full=true
      ;;
    ci_verified:lite)
      echo "Removing label: $label and adding needs_ci:lite"
      remove_label "$label"
      if fleet_on; then add_label "needs_ci:lite"; fi
      needs_ci_lite_label_present=true
      verified_lite=true
      ;;
    # "ci_verified${alternate_python_version}")
    #   echo "Removing label: $label and adding needs_ci${alternate_python_version}"
    #   remove_label "$label"
    #   add_label "needs_ci${alternate_python_version}"
    #   alt_needs_ci_label_present=true
    #   ;;
    # "ci_verified${alternate_python_version}:lite")
    #   echo "Removing label: $label"
    #   remove_label "$label"
    #   ;;
    needs_ci)
      echo "needs_ci label is already present"
      needs_ci_label_present=true
      ;;
    needs_ci:lite)
      echo "needs_ci:lite label is already present"
      needs_ci_lite_label_present=true
      ;;
    # "needs_ci${alternate_python_version}")
    #   echo "needs_ci${alternate_python_version} label is already present"
    #   alt_needs_ci_label_present=true
    #   ;;
    shipit)
      echo "shipit label is present"
      shipit_label_present=true
      ;;
    *)
      echo "Unknown label $label"
      ;;
  esac
done

if [[ "$shipit_label_present" = true ]]; then
  if [[ "$needs_ci_label_present" = false ]] && fleet_on; then
    add_label "needs_ci"
  fi
  if [[ "$alt_needs_ci_label_present" = false && "$current_python_version" != "$alternate_python_version" ]]; then
    add_label "needs_ci${alternate_python_version}"
  fi
else
  if [[ "$needs_ci_lite_label_present" = false && "$needs_ci_label_present" = false ]] && fleet_on; then
    add_label "needs_ci:lite"
  fi
fi

echo "Pull request passed all checkpoints!"

# CI k8s, by the same rules, from its own labels.
if [[ "$verified_full" = true || "$shipit_label_present" = true ]]; then
  k8s_request "ci_k8s" "ci_k8s_full.yml"
fi
if [[ "$verified_lite" = true ]]; then
  k8s_request "ci_k8s:lite" "ci_k8s_lite.yml"
fi
if [[ "$verified_full" = false && "$verified_lite" = false && "$shipit_label_present" = false ]] \
   && ! has_label "ci_k8s" && ! has_label "ci_k8s:lite"; then
  k8s_request "ci_k8s:lite" "ci_k8s_lite.yml"
fi
