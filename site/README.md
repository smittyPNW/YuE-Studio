# YuE Studio website

Production: https://yue-studio.netlify.app

Static HTML/CSS with a small, progressively enhanced Create/Master tab switcher. No client dependencies, analytics, external font requests or sign-up forms.

## Build and preview

Requires Node.js 22 or newer:

```sh
node site/build.mjs
python3 -m http.server 4178 --directory site/dist
```

The build fetches the published v0.4.0 DMG and verifies its pinned SHA-256. A valid cached copy or `RELEASE_DMG_PATH` can be used instead. Model weights, local account files, and the rest of the repository are never copied into the site output. The DMG is a build artifact, not committed source.

## Publish

From the repository root, using an authenticated Netlify CLI linked to the intended site:

```sh
netlify deploy --build
netlify deploy --prod --build
```

The root `netlify.toml` owns the output directory, download headers and `/download` and `/github` shortcuts. The initial deployment was made with the CLI; a GitHub push alone does not automatically publish the website.

## Update a release

Update the pinned release filename, URL and SHA-256 in `build.mjs`, the visible version/download links in `index.html`, and the redirect/download header in `netlify.toml`. Verify the downloaded binary before deploying. Keep the distinction between immediate mastering and separate generation setup explicit.

See `DESIGN.md` for the visual system and `assets/ARTWORK.md` for the generated artwork prompts. Real app screenshots are converted from `docs/screenshots`; self-hosted Barlow fonts retain their OFL notice.
