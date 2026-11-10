# Security

Rim uses Accessibility to filter trackpad input. If you find a way to make Rim block or inject input
unexpectedly, run actions without user intent (e.g. through `rim://` links), or read data it shouldn't,
please report it privately via GitHub's "Report a vulnerability" (Security tab) rather than a public issue.

`rim://run/<action>` deliberately accepts only input-free actions and refuses editing, closing and quitting,
so a web page can't act on the front app.
