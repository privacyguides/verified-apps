# Verified Apps

Privacy Guides is building a database of Android app signing certificate hashes for use with [AppVerifier](https://github.com/soupslurpr/AppVerifier) or [certhashviewer](https://roundsalmon4.github.io/certhashviewer) or `apksigner verify --print-certs`.

**Discussions:** Please discuss anything related to this project [on the Privacy Guides forum](https://discuss.privacyguides.net/t/submit-android-apps-to-our-appverifier-database/38125).

## Submissions

We need you to submit any apps you have installed on your phone [in a new GitHub issue here](https://github.com/privacyguides/verified-apps/issues/new?template=app-submission.yml).

Please submit any apps you'd like, no need to check for existing submissions. We will automatically close issues that are duplicates, but the existence of duplicate issues will help us count how many people may be vouching for a particular submission. We also expect duplicate entries for the same package, because the same package may have a different signature in different app stores.

## Automated Checks

When a maintainer is ready to review a submission, we will run automated checks to check the submission against the following mainstream app sources:

- Accrescent
- AppVerifier's Internal Database
- F-Droid Official
- F-Droid IzzyOnDroid
- Google Play

If the submitted hash matches any of the above, those results will be displayed in a new issue comment and the issue will be labeled accordingly.

We will also check the following:

- Link you provide to a direct APK download
- Link you provide to a developer-run F-Droid repo

We can not automatically validate the *legitimacy* of these sources, but they will be noted for manual review purposes.

## Verification Process

Currently we are checking submitted apps considering one or more of the following factors:

- Signatures from known app stores
- Developer's website, source code repo, or social media indicating their signing key fingerprint
- [Team member](https://discuss.privacyguides.net/u?group=team&order=likes_received&period=all) manual checks of official app downloads
- Team member manual checks of locally installed apps
- Users vouching for PRs (by adding a :+1: reaction or submitting a code review)
- Users vouching for PRs (by submitting a [duplicate issue](https://github.com/privacyguides/verified-apps/issues?q=is%3Aissue%20reason%3Aduplicate))
- Existing matching signatures in our database
  - This could be from a previous submission of the same app from a different source (e.g. the app from Accrescent is currently listed, and we now are confirming the app from F-Droid matches)
  - This could also be from a previous submission of a different app by the same developer, if the developer uses the same signing key for multiple apps.

Information about the data used for verification can be found in the submission's associated issue **and** pull request. We record the issue number in data.yml for future reference, please read both the issue and the linked PR for information.

## Roadmap

This project was started on May 24, 2026, and we are currently collecting submissions to list apps in [data.yml](https://github.com/privacyguides/verified-apps/blob/main/data.yml).

**In the near future,** we will take this data and create a formatted table to make it much easier to copy/paste entries into AppVerifier. We will publish this table on our website and in this repository so you can check the data in either location.

In the longer-term future, we are *considering* creating a fork of AppVerifier with this data included in the internal database automatically, because the developer has indicated the internal database of the official app will no longer be updated with new apps. If you are interested in this functionality, let us know and we will note that.

## Usage by Third-Parties

We are aware some forks of AppVerifier (will?) allow you to import a mass textfile with many signatures to the app's internal database. If this functionality is requested, we will happily generate a custom file with the proper formatting to use for this purpose.

We would also be open to forks of AppVerifier including this data in their internal database by default, and if you are developing a fork and would like to see some changes to this repository that would make it easier for you to use this data for that purpose, let us know.

If you use this data in your app, the [MIT License](./LICENSE.txt) at minimum requires appropriate attribution. We would also appreciate if you could let us know about it so we can potentially link to projects that use this data. We would also recommend:

- Checking the `schema` field in `data.yml` before parsing. The current format may change without notice currently.
- Using the issue number in the data file to provide a link to the issue for users to see the information about how the app was verified.
- Informing your users that new apps can be submitted to our issue tracker, so that we can expand our database and make it more useful for everyone.
- Providing a link to this repository in your app's about page or documentation to credit the project.

You may not imply endorsement by Privacy Guides or the project for your app or project by using this data, but you are free to say "This app uses the Verified Apps database from Privacy Guides" or similar.
