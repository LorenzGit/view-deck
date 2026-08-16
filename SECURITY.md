# Security policy

ViewDeck can load arbitrary websites and run user-configured local commands. Only preview sites, HTML layers, and project folders that you trust. Commands run with the permissions of the current macOS user.

The native HTTP bridge is disabled by default. When enabled, the loaded primary
page can make native requests without browser CORS enforcement to each exact
hostname passed with `--native-http-allow-host`. Keep this list narrow and do
not enable the bridge for untrusted pages. Redirects remain allowlisted, normal
system TLS verification stays enabled, and native cookies and credentials are
not persisted between clean-site runs.

Please do not publish vulnerability details in a public issue. Report security problems through the repository's **Security** tab using GitHub's private vulnerability reporting or private advisory flow.

Include the affected ViewDeck version, macOS version, reproduction steps, and the impact you observed. Please omit credentials, private source code, and other sensitive data.
