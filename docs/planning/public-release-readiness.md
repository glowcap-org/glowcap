# Public release readiness

Status: active plan. This file contains only the work that remains before the
repository and website are public. Complete it from top to bottom, then delete
it. The [roadmap](../roadmap.md) release section carries the work after this
first publication.

GitHub currently reports the repository as private. Its `main` and `dev`
branches contain the prepared release line. The repository description,
website, topics, and Discussions setting are complete. Actions cannot use the
free public-repository runner allocation until the visibility changes.

## 1. Make the repository public

- [ ] **Maintainer:** open **Settings → General → Danger Zone → Change
      repository visibility**, choose **Make public**, and complete GitHub's
      repository-name confirmation. In a signed-out browser, confirm that
      `https://github.com/jimisaacs/glowcap` shows the README.

## 2. Verify GitHub Actions execution

- [ ] **Maintainer:** open **Actions → check**, open the newest failed run on
      `main`, choose **Re-run all jobs**, and confirm that `gates` and
      `macos-runtime` receive runners, show named steps, and finish green on the
      exact `main` commit. The workflows use standard GitHub-hosted runners,
      which are free for public repositories.

## 3. Enable private vulnerability reports

- [ ] **Maintainer:** open **Settings → Security → Advanced Security**. Under
      **Private vulnerability reporting**, choose **Enable**. Done means the
      repository's **Security → Advisories** page offers **Report a
      vulnerability**.

## 4. Publish the website

- [ ] **Maintainer:** open **Settings → Pages**. Under **Build and deployment**,
      set **Source** to **GitHub Actions**. Then open **Actions → pages**, choose
      **Run workflow**, select `main`, and run it. The workflow must finish with
      both `build` and `deploy` green. In a signed-out browser, confirm that
      `https://jimisaacs.github.io/glowcap/` returns the glowcap home page and
      that a Rooms page loads its screenshots. Delete this plan after those
      checks pass.
