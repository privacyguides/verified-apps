# Verified Apps

Privacy Guides is building a database of Android app signing certificate hashes for use with [AppVerifier](https://github.com/soupslurpr/AppVerifier) or [certhashviewer](https://roundsalmon4.github.io/certhashviewer) or `apksigner verify --print-certs`.

**Discussions:** Please discuss anything related to this project [on the Privacy Guides forum](https://discuss.privacyguides.net/t/submit-android-apps-to-our-appverifier-database/38125).

## Submissions

We need you to submit any apps you have installed on your phone [in a new GitHub issue here](https://github.com/privacyguides/verified-apps/issues/new?template=app-submission.yml).

> [!TIP]
> Please submit any apps you'd like, no need to check for existing submissions. We will automatically close issues that are duplicates, but the existence of duplicate issues will help us count how many people may be vouching for a particular submission. We also assume we will see duplicate entries for the same package, because the same package may have a different signature in different app stores.

Currently, we will not merge any apps which cannot be checked by our automated systems (see below), notably any paid apps. In the future we may develop a process for multiple people to vouch for the validity of these apps.

## Automated Checks

When a maintainer is ready to review a submission, we will run automated checks to check the submission against AppVerifier's legacy internal database and the following mainstream app sources:

- Accrescent
- F-Droid Official
- F-Droid IzzyOnDroid
- Google Play

If the submitted hash matches any of the above, those results will be displayed in a new issue comment and the issue will be labeled accordingly.

We will also check the following:

- Link you provide to a direct APK download
- Link you provide to a developer-run F-Droid repo

We can not automatically validate the *legitimacy* of these sources, but they will be noted for manual review purposes. If we believe the direct sources are legitimate, we will add them to the database alongside any app store releases.

We will also check submissions against the hashes [submitted to the GrapheneOS forum](https://discuss.grapheneos.org/d/15368-lets-compare-hashes-for-apps-not-in-appverifiers-database) and compiled by @RoundSalmon4 at <https://github.com/RoundSalmon4/AppVerifier/releases>. This information is **not** used for any database-related purposes (**not** added to data.yml), because the comments in that thread are unverified user-submissions. However, they can act as an additional data point that someone is vouching for that submission. Therefore, matches will merely be noted in the GitHub issue here for a particular submission. 

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

Information about the data used for verification can be found in the submission's associated issue. We record the issue number in data.yml for future reference, please read both the issue and any linked PR (if applicable) for information.

## Roadmap

This project was started on May 24, 2026, and we are currently collecting submissions to list apps in [data.yml](https://github.com/privacyguides/verified-apps/blob/main/data.yml).

**In the near future,** we will take this data and create a formatted table to make it much easier to copy/paste entries into AppVerifier. We will publish this table on our website and in this repository so you can check the data in either location.

In the longer-term future, we are *considering* creating a fork of AppVerifier with this data included in the internal database automatically, because the developer has indicated the internal database of the official app will no longer be updated with new apps. If you are interested in this functionality, let us know and we will note that.

## Usage by Third-Parties

We are aware some forks of AppVerifier (will?) allow you to import a mass textfile with many signatures to the app's internal database. If this functionality is requested, we will happily generate a custom file with the proper formatting to use for this purpose.

We would also be open to forks of AppVerifier including this data in their internal database by default, and if you are developing a fork and would like to see some changes to this repository that would make it easier for you to use this data for that purpose, let us know.

If you use this data in your app, the [MIT License](./LICENSE.txt) at minimum requires appropriate attribution. We would also appreciate if you could let us know about it so we can potentially link to projects that use this data. We would also recommend:

- Checking the `schema` field in `data.yml` before parsing. The current format may change without notice currently (besides thus number changing), as we work out which data we need stored for our own purposes.
- Using the issue number in the data file to provide a link to the issue for users to see the information about how the app was verified.
- Informing your users that new apps can be submitted to our issue tracker, so that we can expand our database and make it more useful for everyone.
- Providing a link to this repository in your app's about page or documentation to credit the project.

> [!NOTE]
> You may not imply endorsement by Privacy Guides or the project for your app or project by using this data, but you are free to say "This app uses the Verified Apps database from Privacy Guides" or similar.

### Verifying Attestations

If you are downloading `data.yml` for your own purposes, we highly recommend verifying that the file you have downloaded was built by us on GitHub Actions using our automated workflows. We allow you to verify this through the use of [provenance attestations](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations). A list of our *current* attestations can be found here: <https://github.com/privacyguides/verified-apps/attestations>

Provenance attestations guarantee the file you have was built from a well-defined process. Attestations also allow us to revoke bad copies of the database if needed, because we can delete the attestation on our end, which will in turn cause your verification process to fail. As such, we recommend checking these attestations whenever is reasonably possible, so you are informed of revocations in a timely manner.

> [!IMPORTANT]
> We **automatically delete** (revoke) attestations in this repo after 5 days, except for the latest one (if it's older than 5 days), and any attestations related to our (unrevoked) [releases](https://github.com/privacyguides/verified-apps/releases). In this sense, copies of our database "expire" after 5 days unless they are releases. If you verify attestations in your build process automatically, we recommend always downloading the latest copy of `data.yml` each time. If you rely on verifying the provenance of our data at any time beyond 5 days, we recommend only using copies of `data.yml` from our releases as those attestations will never be deleted unless we need to revoke one due to bad data.

We *especially* recommend checking this if you are incorporating this data in your own app, to strenghten your own supply-chain security when grabbing data from an upstream source (us). One example of how to do this in your GitHub workflows can be found here: <https://github.com/RoundSalmon4/AppVerifierBG/pull/12>

#### Verifying data.yml in main branch

If you download the latest copy of `data.yml` directly from this repo, you can verify its provenance using the `gh` command line tool:

```
gh attestation verify --owner privacyguides data.yml
```

An even more robust check can be done by verifying the signature was made with our organization-wide signing workflow:

```
gh attestation verify -R privacyguides/verified-apps --cert-identity-regex 'https://github.com/privacyguides/.github/.github/workflows/sign-artifact.yml*' data.yml
```

#### Verifying data.yml in a tagged release

If you clone this repository and checkout a tagged release, you can verify your copy matches the immutable release we've published:

```
gh release verify-asset [RELEASE] data.yml
```

For example, you'd run `gh release verify-asset 3.20260527 data.yml` inside this repo to check your copy against [3.20260527](https://github.com/privacyguides/verified-apps/releases/tag/3.20260527).

> [!TIP]
> In addition to using the online `gh` CLI, you should be able to verify these files with any [SLSA build verifiers](https://slsa.dev/spec/v1.2/verifying-artifacts), or [verify these attestations offline](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/verify-attestations-offline).

### Schema

```yaml
schema: # Required. Current version of the data file's schema.
packages: # Required. Contains all verification data.
  - package: # Required. Package's Android ID (e.g. org.thoughtcrime.securesms).
    signature: # Required.
      - fingerprint: # Required. SHA-256 hash of the app's signing certificate. Note that this may be a multiline string for certain apps, see `com.google.android.inputmethod.latin` in data.yml for example.
        sources:
          - name: # Required. Name of the source we obtained the app from (see full list below).
            issue: # Optional. Number of the GitHub issue where the app was submitted, can be used by users to find additional information about the verification.
            apk: # Optional.
              sha256: # Optional. SHA-256 hash of the APK *file* we verified.
              link: # Optional. Link to download the APK file we verified.
              repo: # Optional. Link to F-Droid repo we tested, if applicable (and not F-Droid Official or IzzyOnDroid).
```


Each package will have a list of signing key fingerprints. Multiple fingerprints for apps is generally expected, because many apps use Google Play App Signing or are built by F-Droid without reproducible builds, meaning they are signed by the respective app store instead of directly by the developer.

With each key fingerprint are the sources where we found that signing key. The source can be identified by its name (see below), and we also record the SHA-256 hash of the APK *file* we verified, and in the case of direct APK downloads and custom F-Droid repos we record the exact source. More details can always be found in the corresponding GitHub issue for a submission.

#### Source Names

We always test submissions against five mainstream app stores. If the submission matches what is found in that app store, we will list it and the `name:` value will always be one of the following:

- `AppVerifier` - Signatures which are already in [AppVerifier's own internal database](https://github.com/soupslurpr/AppVerifier/blob/main/app/src/main/kotlin/dev/soupslurpr/appverifier/InternalVerificationInfoDatabase.kt) (which no longer accepts submissions).
- `Accrescent` - Signatures we checked against the APK file in Accrescent's app store repository.
- `F-Droid` - Signatures we checked against the APK file in the **official** (default) F-Droid repository.
- `F-Droid (IzzyOnDroid)` - Signatures we checked against the APK file in the [IzzyOnDroid](https://izzyondroid.org/) F-Droid repository.
- `Google Play` - Signatures we checked against the APK file in Google Play.

Additionally, we check direct links to APK files (e.g. GitHub Releases) and custom F-Droid repos (i.e. developer-run) when provided by the submitter. We will include the `link:` or `repo:` key respectively to assist others in finding where exactly the verification was obtained from if it was not one of the five well-known sources.

Signatures we obtained from a direct APK link will currently always have the `name:` value set to `Direct APK Link`.

Signatures we obtained from a custom F-Droid repo will always have a `name:` value formatted as `F-Droid (example.com)` where `example.com` is the FQDN of the custom F-Droid repository. For example, the repository `https://app.simplex.chat/fdroid/repo` will be listed under `F-Droid (app.simplex.chat)`.

Finally, any other sources not described above will be named `Custom (example)` where `example` can be any ASCII printable character (including spaces).

#### Example

```yaml
schema: 3
packages:
  - package: chat.simplex.app
    signature:
      - fingerprint: 3C:52:C4:FD:3C:AD:1C:07:C9:B0:0A:70:80:E3:58:FA:B9:FE:FC:B8:AF:5A:EC:14:77:65:F1:6D:0F:21:AD:85
        sources:
          - name: AppVerifier
            issue: 493
          - name: Direct APK Link
            issue: 493
            apk:
              sha256: 391f3560a0fad696be5a6b3efde9544a1cf4d3a42a8d6eed09f1cb8c854ccff8
              link: https://github.com/simplex-chat/simplex-chat/releases/latest/download/simplex-aarch64.apk
          - name: F-Droid (app.simplex.chat)
            issue: 493
            apk:
              repo: https://app.simplex.chat/fdroid/repo?fingerprint=9F358FF284D1F71656A2BFAF0E005DEAE6AA14143720E089F11FF2DDCFEB01BA
      - fingerprint: 5E:3E:DC:C2:00:FB:A8:D5:F4:88:F3:CA:4C:32:5B:05:78:C5:6A:9C:03:A1:CC:B5:92:9C:D7:5C:7E:57:E2:4D
        sources:
          - name: AppVerifier
            issue: 565
          - name: Google Play
            issue: 565
            apk:
              sha256: 95e555c92391049e08df56b712cea59769e3d0ac4276c0ca649814a03e7b2671
      - fingerprint: AE:C1:95:DC:FD:46:14:BD:3A:91:EC:26:D1:D5:14:C8:75:71:C5:CC:8D:CF:48:08:3F:92:83:14:3C:A2:B9:A6
        sources:
          - name: AppVerifier
            issue: 564
          - name: F-Droid
            issue: 564
            apk:
              sha256: 6186c80da39dd7566e1c64cee096b0623d8dfb171627d50525f64dd420ed9345
```
