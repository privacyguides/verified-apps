# Verified Apps

Privacy Guides is building a database of Android app signing certificate hashes for use with [AppVerifier](https://github.com/soupslurpr/AppVerifier) or [https://roundsalmon4.github.io/certhashviewer/](certhashviewer) or `apksigner verify --print-certs`.

**Discussions:** Please discuss anything related to this project [on the Privacy Guides forum.](https://discuss.privacyguides.net/t/submit-android-apps-to-our-appverifier-database/38125)

**Submissions:** We need you to submit any apps you have installed on your phone [in a new GitHub issue here.](https://github.com/privacyguides/verified-apps/issues/new?template=app-submission.yml) If your submission matches our automatic checks we will [open a PR](https://github.com/privacyguides/verified-apps/pulls), if it does not it will need manual approval. We will still manually check all automatically opened PRs, but the PRs will contain information obtained from our automated checks which will be used to guide approvals.

**Contributions:** In addition to submitting new apps, submitting code reviews/approvals or :+1: reactions to open PRs to indicate the fingerprint matches what you have locally would be much appreciated. Comments in issues/PRs indicating how you came about verifying your APK locally would also be appreciated.

## Automated Checks

Submitted apps are automatically checked against:

- Accrescent
- AppVerifier's Internal Database
- F-Droid Official
- F-Droid IzzyOnDroid
- Google Play

If the submitted hash matches any of the above, the PR will be labeled accordingly.

We will also check the following:

- Link you provide to a direct APK download
- Link you provide to a developer-run F-Droid repo

We do not automatically validate the legitimacy of these sources, but they will be noted for manual review purposes.

## Verification Process

Currently we are checking submitted apps considering one or more of the following factors:

- Signatures from known app stores
- Developer's website, source code repo, or social media indicating their signing key fingerprint
- [Team member](https://discuss.privacyguides.net/u?group=team&order=likes_received&period=all) manual checks of official app downloads
- Team member manual checks of locally installed apps
- Users vouching for PRs (by adding a :+1: reaction or submitting a code review)
- Users vouching for PRs (by submitting a [duplicate issue](https://github.com/privacyguides/verified-apps/issues?q=is%3Aissue%20reason%3Aduplicate))

Information about the data used for verification can be found in the submission's associated issue **and** pull request. We record the issue number in data.yml for future reference, please read both the issue and the linked PR for information.

## Roadmap

This project was started on May 24, 2026, and we are currently collecting submissions to list apps in [data.yml](https://github.com/privacyguides/verified-apps/blob/main/data.yml).

**In the near future,** we will take this data and create a formatted table to make it much easier to copy/paste entries into AppVerifier. We will publish this table on our website and in this repository so you can check the data in either location.

In the longer-term future, we are *considering* creating a fork of AppVerifier with this data included in the internal database automatically, because the developer has indicated the internal database of the official app will no longer be updated with new apps. If you are interested in this functionality, let us know and we will note that.

We are also aware some forks of AppVerifier (will?) allow you to import a mass textfile with many signatures to the app's internal database. If this functionality is requested we will happily generate a custom file to use for this purpose. We would also be open to forks of AppVerifier including this data in their internal database by default, and if you are developing a fork and would like to see some changes to this repository that would make it easier for you to use this data for that purpose, let us know.
