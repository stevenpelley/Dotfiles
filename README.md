Dotfiles
========

My home directory is a dotfiles repo.  .ignore contains a single line, "*".
Files must be explicitly/force addeded via `git add -f ...`
Set up a new home directory with:
```
cd ~
git init
git remote add origin https://github.com/stevenpelley/Dotfiles.git
git fetch
git checkout -f master
```

This concept is borrowed from https://drewdevault.com/2019/12/30/dotfiles.html
