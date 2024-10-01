# Cool `neovim` tips and tricks

## insert text at start of multiple lines

- `Ctrl+v`- To enter Visual Block mode.
- Use `j`/`k` to select the lines.
- Capital `I` or `Shift+i`- Enter insert mode before the first character.
- Insert desired text.
- `<Esc>` - Exit insert mode and finish block append.

## insert text at the end of multiple lines

- `Ctrl+v`- To enter Visual Block mode.
- Use `j`/`k` to select the lines.
- `$` to move at the end of the line.
- Capital `A` or `Shift+a`- Enter insert mode after last character.
- Insert desired text.
- `<Esc>` - Exit insert mode and finish block append.

## select words and update like `ctrl+d` in `vscode`

- Put the cursor over the word you want to edit
- Press `c` + `g` + `n`, the current word will be deleted and you can type the new word as replacement
- Press `Esc` to escape and then press `.` to replace the next occurrence of the word
- You can use `ctrl+N` or `ctrl+n` to move back and forth the word occurrences before pressing `.`. This gives you the option to select which word to replace.

## select(highlight) a word, copy it then paste

- Hit `v` for visual mode
- Then `i` for inside
- Then `w` for word
- You just highlighted a whole word
- Then use `y` to `yank` it.
- Now you can move your cursor anywhere and hit `p` to put(paste) it.
> Make sure you are in `visual` mode or `normal` mode before you `p` put

## replacing the variable name and all its instances

- Press `<leader>cr` to do `lsp` rename, (I think this is the default from `lazyvim`, it might be different from `vim`, `neovim` or any distro in general)
- Type the new `variable` name
