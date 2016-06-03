set -e

SOURCE_OWNER=
DESTINATION_OWNER=
SOURCE_REPO=
DESTINATION_REPO=

AUTHORIZATION_TOKEN=

escape() {
	sed \
		--expression 's/\\/\\\\/g' \
		--expression 's/\t/\\t/g' \
		--expression 's/\r//g' \
		--expression 's/"/\\"/g' \
		<<< "${1}" | \
		sed --expression ':a;N;$!ba;s/\n/\\n/g'
}

raw_issues=$(curl \
	--silent \
	--request GET \
	--header "Authorization: token ${AUTHORIZATION_TOKEN}" \
	--url "https://api.github.com/repos/${SOURCE_OWNER}/${SOURCE_REPO}/issues?per_page=100")
issue_count=$(jq "length" --raw-output <<< ${raw_issues})

for i in $(seq 0 $((${issue_count} - 1))); do
	if grep --invert-match null <<< $(jq ".[${i}].pull_request" <<< ${raw_issues}) > /dev/null; then
		continue
	fi

	echo "Processing #$(jq ".[${i}].number" <<< ${raw_issues}): $(jq ".[${i}].title" <<< ${raw_issues})"

	issue_body=$(cat <<-EOF
	<a href=$(jq ".[${i}].user.url" <<< ${raw_issues})><img src=$(jq ".[${i}].user.avatar_url" <<< ${raw_issues}) align="left" width="96" height="96" hspace="10"></img></a>
	**Issue by [$(jq ".[${i}].user.login" --raw-output <<< ${raw_issues})]($(jq ".[${i}].user.url" --raw-output <<< ${raw_issues}))**
	
	----
	
	$(jq ".[${i}].body" --raw-output <<< ${raw_issues})
	EOF
	)

	raw_comments=$(curl \
		--silent \
		--request GET \
		--header "Authorization: token ${AUTHORIZATION_TOKEN}" \
		--url "https://api.github.com/repos/${SOURCE_OWNER}/${SOURCE_REPO}/issues/$(jq ".[${i}].number" <<< ${raw_issues})/comments")
	comment_count=$(jq "length" --raw-output <<< ${raw_comments})

	comments="[]"
	for j in $(seq 0 $((${comment_count} - 1))); do
		comment_body=$(cat <<-EOF
		<a href=$(jq ".[${j}].user.url" <<< ${raw_comments})><img src=$(jq ".[${j}].user.avatar_url" <<< ${raw_comments}) align="left" width="48" height="48" hspace="10"></img></a>
		**Comment by [$(jq ".[${j}].user.login" --raw-output <<< ${raw_comments})]($(jq ".[${j}].user.url" --raw-output <<< ${raw_comments}))**

		----

		$(jq ".[${j}].body" --raw-output<<< ${raw_comments})
		EOF
		)
		created_at=$(jq ".[${j}].created_at" <<< ${raw_comments})

		comments=$(jq ". + [{created_at: ${created_at}, body: \"$(escape "${comment_body}")\"}]" <<< ${comments})
	done

	data="{
		\"issue\": {
			\"title\": $(jq ".[${i}].title" <<< ${raw_issues}),
			\"body\": \"$(escape "${issue_body}")\",
			\"created_at\": $(jq ".[${i}].created_at" <<< ${raw_issues}),
			\"updated_at\": $(jq ".[${i}].updated_at" <<< ${raw_issues}),
			\"closed\": $(jq ".[${i}].closed // false" <<< ${raw_issues})
		},
		\"comments\": ${comments}
	}"

#			\"closed_at\": $(jq ".[${i}].closed_at" <<< ${raw_issues})
#			\"assignee\": $(jq ".[${i}].assignee.login" <<< ${raw_issues}),
#			\"milestone\": $(jq ".[${i}].milestone" <<< ${raw_issues}),
#			\"labels\": $(jq "[.[${i}].labels[].name]" <<< ${raw_issues})

	result=$(curl \
		--silent \
		--request POST \
		--header "Authorization: token ${AUTHORIZATION_TOKEN}" \
		--header "Accept: application/vnd.github.golden-comet-preview+json" \
		--url "https://api.github.com/repos/${DESTINATION_OWNER}/${DESTINATION_REPO}/import/issues" \
		--data "@-" <<< "${data}")

	status_url=$(jq ".url" --raw-output <<< ${result})
	stat=""
	while [ 1 ]; do
		echo "Waiting for import"
		stat=$(curl \
			--silent \
			--request GET \
			--header "Authorization: token ${AUTHORIZATION_TOKEN}" \
			--header "Accept: application/vnd.github.golden-comet-preview+json" \
			--url ${status_url})

		if grep imported <<< $(jq ".status" <<< ${stat}) > /dev/null; then
			break
		fi

		sleep 1
	done

	raw_issue=$(curl \
		--silent \
		--request GET \
		--header "Authorization: token ${AUTHORIZATION_TOKEN}" \
		--header "Accept: application/vnd.github.golden-comet-preview+json" \
		--url $(jq ".issue_url" --raw-output <<< ${stat}))

	curl \
		--silent \
		--request POST \
		--header "Authorization: token ${AUTHORIZATION_TOKEN}" \
		--header "Accept: application/vnd.github.golden-comet-preview+json" \
		--url $(jq ".[${i}].comments_url" --raw-output <<< ${raw_issues}) \
		--data "{\"body\": \"Moved to $(jq ".html_url" --raw-output <<< ${raw_issue})\"}"

	curl \
		--silent \
		--request PATCH \
		--header "Authorization: token ${AUTHORIZATION_TOKEN}" \
		--header "Accept: application/vnd.github.golden-comet-preview+json" \
		--url $(jq ".[${i}].url" --raw-output <<< ${raw_issues}) \
		--data '{"state": "closed"}'
done
