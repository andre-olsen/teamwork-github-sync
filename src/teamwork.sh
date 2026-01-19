#!/usr/bin/env bash

teamwork::get_task_id_from_body() {
  local body=$1
  local task_ids=()

  pat='tasks\/([0-9]{1,})'
  while [[ $body =~ $pat ]]; do
    task_ids+=( "${BASH_REMATCH[1]}" )
    body=${body#*"${BASH_REMATCH[0]}"}
  done

  local task_ids_str
  task_ids_str=$(printf ",%s" "${task_ids[@]}")
  task_ids_str=${task_ids_str:1} # remove initial comma
  echo "$task_ids_str"
}

teamwork::get_project_id_from_task() {
  local -r task_id=$1

  if [ "$ENV" == "test" ]; then
    echo "$task_id"
    return
  fi

  response=$(
    curl "$TEAMWORK_URI/projects/api/v1/tasks/$task_id.json" -u "$TEAMWORK_API_TOKEN"':' |\
      jq -r '.["todo-item"]["project-id"]'
  )
  echo "$response"
}

teamwork::get_matching_board_column_id() {
  local -r column_name=$1

  if [ -z "$column_name" ]; then
    return
  fi

  if [ "$ENV" == "test" ]; then
    echo "$TEAMWORK_PROJECT_ID"
    return
  fi

  response=$(
    curl "$TEAMWORK_URI/projects/$TEAMWORK_PROJECT_ID/boards/columns.json" -u "$TEAMWORK_API_TOKEN"':' |\
      jq -r --arg column_name "$column_name" '[.columns[] | select(.name | contains($column_name))] | map(.id)[0]'
  )

  if [ "$response" = "null" ]; then
    return
  fi

  echo "$response"
}

teamwork::move_task_to_column() {
  local -r task_id=$TEAMWORK_TASK_ID
  local -r column_name=$1

  if [ -z "$column_name" ]; then
    log::message "No column name provided"
    return
  fi

  local -r column_id=$(teamwork::get_matching_board_column_id "$column_name")
  if [ -z "$column_id" ]; then
    log::message "Failed to find a matching board column for '$column_name'"
    return
  fi

  if [ "$ENV" == "test" ]; then
    log::message "Test - Simulate request. Task ID: $TEAMWORK_TASK_ID - Project ID: $TEAMWORK_PROJECT_ID - Column ID: $column_id"
    return
  fi

  response=$(curl -X "PUT" "$TEAMWORK_URI/tasks/$TEAMWORK_TASK_ID.json" \
      -u "$TEAMWORK_API_TOKEN"':' \
      -H 'Content-Type: application/json; charset=utf-8' \
      -d "{ \"todo-item\": { \"columnId\": $column_id } }" )

  log::message "$response"
}

teamwork::get_custom_field_id() {
  local -r field_name=$1

  if [ "$ENV" == "test" ]; then
    echo "123"
    return
  fi

  # URL encode the field name for the query parameter
  local -r encoded_field_name=$(printf %s "$field_name" | jq -sRr @uri)

  response=$(
    curl "$TEAMWORK_URI/projects/api/v3/customfields.json?searchTerm=$encoded_field_name" -u "$TEAMWORK_API_TOKEN"':' |\
      jq -r --arg field_name "$field_name" '[.customFields[] | select(.name == $field_name)] | map(.id)[0]'
  )

  if [ "$response" = "null" ] || [ -z "$response" ]; then
    log::message "Custom field '$field_name' not found"
    return
  fi

  echo "$response"
}

teamwork::update_task_custom_field() {
  local -r task_id=$TEAMWORK_TASK_ID
  local -r field_name=$1
  local -r field_value=$2

  local -r custom_field_id=$(teamwork::get_custom_field_id "$field_name")

  if [ -z "$custom_field_id" ]; then
    log::message "Cannot update custom field - field ID not found for '$field_name'"
    return
  fi

  if [ "$ENV" == "test" ]; then
    log::message "Test - Simulate request. Task ID: $TEAMWORK_TASK_ID - Custom Field: $field_name (ID: $custom_field_id) - Value: $field_value"
    return
  fi

  # Use V1 API to update task with custom field
  # Properly escape the field_value for JSON using jq
  local -r json_payload=$(jq -n \
    --arg field_value "$field_value" \
    --argjson custom_field_id "$custom_field_id" \
    '{"todo-item": {"customFields": [{"customFieldId": $custom_field_id, "value": $field_value}]}}')

  response=$(curl -X "PUT" "$TEAMWORK_URI/tasks/$task_id.json" \
      -u "$TEAMWORK_API_TOKEN"':' \
      -H 'Content-Type: application/json; charset=utf-8' \
      -d "$json_payload" )

  log::message "$response"
}

teamwork::add_comment() {
  local -r body=$1

  if [ "$ENV" == "test" ]; then
    log::message "Test - Simulate request. Task ID: $TEAMWORK_TASK_ID - Comment: ${body//\"/}"
    teamwork::add_reset_comment
    return
  fi

  response=$(curl -X "POST" "$TEAMWORK_URI/tasks/$TEAMWORK_TASK_ID/comments.json" \
        -u "$TEAMWORK_API_TOKEN"':' \
        -H 'Content-Type: application/json; charset=utf-8' \
        -d "{ \"comment\": { \"body\": \"${body//\"/}\", \"notify\": false, \"content-type\": \"text\", \"isprivate\": true } }" )

  log::message "$response"
  
  # Add a reset comment to prevent subsequent manual comments from inheriting private/notify settings
  teamwork::add_reset_comment
}

teamwork::add_reset_comment() {
  if [ "$ENV" == "test" ]; then
    log::message "Test - Simulate reset comment. Task ID: $TEAMWORK_TASK_ID"
    return
  fi

  # Add a minimal public comment with default notify settings to reset UI state
  # This prevents subsequent manual comments from inheriting the private/no-notify settings
  # Using a single space as the body to minimize visibility while being valid
  response=$(curl -X "POST" "$TEAMWORK_URI/tasks/$TEAMWORK_TASK_ID/comments.json" \
        -u "$TEAMWORK_API_TOKEN"':' \
        -H 'Content-Type: application/json; charset=utf-8' \
        -d '{ "comment": { "body": " ", "notify": "", "content-type": "text", "isprivate": false } }' )

  # Extract the comment ID from the response
  # Teamwork API v1 may return 'commentId' or 'id' depending on the response structure
  local comment_id
  comment_id=$(echo "$response" | jq -r '.commentId // .id // empty')
  
  if [ -n "$comment_id" ]; then
    log::message "Reset comment created with ID: $comment_id, deleting it..."
    # Delete the reset comment immediately to avoid clutter
    delete_response=$(curl -X "DELETE" "$TEAMWORK_URI/comments/$comment_id.json" \
          -u "$TEAMWORK_API_TOKEN"':')
    log::message "Reset comment deleted: $delete_response"
  else
    log::message "Could not extract comment ID from response, reset comment may remain: $response"
  fi
}

teamwork::add_tag() {
  local -r tag_name=$1

  if [ "$ENV" == "test" ]; then
    log::message "Test - Simulate request. Task ID: $TEAMWORK_TASK_ID - Tag Added: ${tag_name//\"/}"
    return
  fi

  if [ "$AUTOMATIC_TAGGING" == true ]; then
    response=$(curl -X "PUT" "$TEAMWORK_URI/tasks/$TEAMWORK_TASK_ID/tags.json" \
        -u "$TEAMWORK_API_TOKEN"':' \
        -H 'Content-Type: application/json; charset=utf-8' \
        -d "{ \"tags\": { \"content\": \"${tag_name//\"/}\" } }" )

    log::message "$response"
  fi
}

teamwork::remove_tag() {
  local -r tag_name=$1

  if [ "$ENV" == "test" ]; then
    log::message "Test - Simulate request. Task ID: $TEAMWORK_TASK_ID - Tag Removed: ${tag_name//\"/}"
    return
  fi

  if [ "$AUTOMATIC_TAGGING" == true ]; then
    response=$(curl -X "PUT" "$TEAMWORK_URI/tasks/$TEAMWORK_TASK_ID/tags.json" \
          -u "$TEAMWORK_API_TOKEN"':' \
          -H 'Content-Type: application/json; charset=utf-8' \
          -d "{ \"tags\": { \"content\": \"${tag_name//\"/}\" },\"removeProvidedTags\":\"true\" }" )

    log::message "$response"
  fi
}

teamwork::pull_request_opened() {
  local -r pr_url=$(github::get_pr_url)

  # Update the PR custom field with the PR URL
  teamwork::update_task_custom_field "PR" "$pr_url"

  teamwork::add_tag "PR Open"
  teamwork::move_task_to_column "$BOARD_COLUMN_OPENED"
}

teamwork::pull_request_closed() {
  local -r pr_url=$(github::get_pr_url)
  local -r pr_merged=$(github::get_pr_merged)

  if [ "$pr_merged" == "true" ]; then
    # Update PR custom field to indicate the PR was merged
    teamwork::update_task_custom_field "PR" "$pr_url (Merged)"
    teamwork::add_tag "PR Merged"
    teamwork::remove_tag "PR Open"
    teamwork::remove_tag "PR Approved"
    teamwork::move_task_to_column "$BOARD_COLUMN_MERGED"
  else
    # Update PR custom field to indicate the PR was closed without merging
    teamwork::update_task_custom_field "PR" "$pr_url (Closed)"
    teamwork::remove_tag "PR Open"
    teamwork::remove_tag "PR Approved"
    teamwork::move_task_to_column "$BOARD_COLUMN_CLOSED"
  fi
}

teamwork::pull_request_review_submitted() {
  local -r review_state=$(github::get_review_state)

  # Only add a tag if the PR has been approved
  if [ "$review_state" == "approved" ]; then
    teamwork::add_tag "PR Approved"
  fi
}

teamwork::pull_request_review_dismissed() {
  # No action needed for dismissed reviews as the custom field already tracks the PR
  log::message "Review dismissed - no action taken"
}
