# Install `oh-my-zsh`

- Instal zsh from arch linux

```zsh
yay -S zsh
```

- Change shell to zsh, check first current shell

```zsh
echo $SHELL
```

- List installed shells

```zsh
chsh -l
```

- Update shell to `zsh`

```zsh
chsh -s /bin/zsh
```

- Finally install `oh my zsh`

```zsh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" | zsh
```

- Install the following plugins

`zsh-autosuggestions`

```zsh
git clone https://github.com/zsh-users/zsh-autosuggestions.git $ZSH_CUSTOM/plugins/zsh-autosuggestions
```

`zsh-syntax-highlighting`

```zsh
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git $ZSH_CUSTOM/plugins/zsh-syntax-highlighting
```

- Add the plugins to your `.zshrc` file

```zsh
plugins=(git
fzf
dotenv
nvm
archlinux
zsh-autosuggestions
zsh-syntax-highlighting
)
```

## `nvm` on `zsh` causing slow startup

add lazy loading to your `.zshrc` file

```zsh
zstyle ':omz:plugins:nvm' lazy yes`
```

# Installing `dotnet` on `linux`

Download `dotnet-install.sh` from [here](https://dot.net/v1/dotnet-install.sh)

Change to execute `dotnet-install.sh`

```zsh
$ chmod +x dotnet-install.sh
```

- Run the following command:

```zsh
bash ./dotnet-install.sh --install-dir /usr/share/dotnet -channel Current -version latest
```

- Add the it to the PATH of your shell, for `zsh` open `~/.zshrc`, for `bash` open `~/.bashrc` and add the following line:

```zsh
export PATH="$PATH:/usr/share/dotnet"
```

- You need to add a symbolic for dotnet, run the following command to do so:

```bash
sudo ln -s /usr/share/dotnet/dotnet /usr/bin/dotnet
```

Where `/usr/share/dotnet/` in the command is the path and the additional `dotnet` is the `executable`

## Install `starship` shell prompt

- Install starship from [here](http://starship.rs/guide/#-installation)
- Create a `starship.toml` file in `~/.config`, copy the content from [here](/starship.toml)
- Install Meslo Nerd Fonts
  > For `xterm` get it from [here](/Fonts/xterm/)
  > For `vscode` get from [here](/Fonts/vscode/)
- Open `~/.Xresources` and change the font for **xterm** to this: `XTerm*faceName:          MesloLGS NF`
- Open `vscode` and set the terminal font by opening _Settings ->_ **search: terminal font** and set the value to `MesloLGL Nerd Font`

# Installing `npm`

We need to install `nvm` first.

Run the following commands:

```zsh
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.1/install.sh | zsh
```

## Installing `npm` using `nvm`

To install npm run the following command:

```zsh
nvm install --lts
```

Check the installed version using the following

Check `npm` version

```zsh
nvm --version
```

Check `node` version

```zsh
node --version
```

Check `nvm` version

```zsh
nvm --version
```

## Configuring Arch Linux in VMware Player

### Missing screen resolution

If you cannot find the correct screen resolution on your guest Arch Linux using VMware, run the following steps.

Install `open-vm-tools`

```zsh
sudo pacman open-vm-tools
```

Lets add the missing resolution:

Run the following command to get the resolution you want

```zsh
cvt 2560 1080 60
```

The command above will show the screen resolution of `2560` by `1080` on `60hz`

You should get something like this

```zsh
Modeline "2560x1080_60.00"  230.00  2560 2720 2992 3424  1080 1083 1093 1120 -hsync +vsync
```

Now run the following command to add a new mode

```zsh
xrandr --newmode "2560x1080_60.00"  230.00  2560 2720 2992 3424  1080 1083 1093 1120 -hsync +vsync
```

Now we need to add the new mode to `xrandr` using the following command

```zsh
xrandr --addmode Virtual1 2560x1080_60.00
```

Where `Virtual1` is your monitor and `2560x1080` is the screen mode you want to use

Last step is to add the following modules to `mkinicpio.conf`

Edit `/etc/mkinitcpio.conf` and replace `MODULES=""` with

```zsh
MODULES=(vsock vmw_vsock_vmci_transport vmw_balloon vmw_vmci vmgfx)
```

Restart your machine and you should get the resolution, you set, `PRO TIP: force VMware to fullscreen`

### Enabling Shared folders

Adding shared folder from `Host` to be accessible in the `guest` machine.

- Make sure from VMware player under **Settings -> Options -> Shared folder**. Select the folder you want to share with the guest machine.

- Create a folder in your `Guest`. For example `/home/stifmiester/Shared`

- Mount the folder from `Host` to the folder your created in your `Guest`

```zsh
/usr/bin/vmhgs-fuse -o auto_unmount,allow_other .host:/ /home/stifmiester/Shared
```

- Next is to update your `/etc/fstab`

```zsh
sudo nano /etc/fstab
```

```zsh
*** Note in Thunar By default, Thunar will not show in devices any partitions defined in /etc/fstab besides the root partition.

We can change that by adding the option x-gvfs-show to fstab for the partition we wish to show.

Add the the following code to the end of the file
```

```zsh
.host:/ /home/stifmiester/Shared fuse.vmhgfs-fuse defaults,allow_other 0 0
```

### Change Background Image in Login Screen in EndeavourOS

`Note: This is for users using lightdm-gtk-greeter`

Run the following code to edit the config for `lightdm`

```zsh
sudo nano /etc/lightdm/slick-greeter.conf
```

Edit the value for `background`

Make sure the file path is sufficient permision for the greeter to read. Here is my example:

`background=/usr/share/endeavouros/backgrounds/fiery-rick.png`

sample `Greeter` config

```json
[Greeter]
background=/usr/share/endeavouros/backgrounds/4karchlinux.png
draw-user-backgrounds=false
draw-grid=false
theme-name=Arc-Dark
icon-theme-name=Qogir
cursor-theme-name=Qogir
cursor-theme-size=16
show-a11y=false
show-power=false
background-color=#000000
only-on-monitor=DP-1
```

\*\*Note find monitor `only-on-monitory` value from ARandR

sample copy wallpaper to `/usr/share`

```zsh
sudo cp ~/src/devmachine-dot-files/wallpapers/4karchlinux.png /usr/share/endeavouros/backgrounds/4karchlinux.png
```

All params for `Greeter` from [source](https://github.com/linuxmint/slick-greeter)

```json
[Greeter]
# LightDM GTK+ Configuration
# Available configuration options listed below.
#
# activate-numlock=Whether to activate numlock. This features requires the installation of numlockx. (true or false)
# background=Background file to use, either an image path or a color (e.g. #772953)
# background-color=Background color (e.g. #772953), set before wallpaper is seen
# draw-user-backgrounds=Whether to draw user backgrounds (true or false)
# draw-grid=Whether to draw an overlay grid (true or false)
# show-hostname=Whether to show the hostname in the menubar (true or false)
# show-power=Whether to show the power indicator in the menubar (true or false)
# show-a11y=Whether to show the accessibility options in the menubar (true or false)
# show-keyboard=Whether to show the keyboard indicator in the menubar (true or false)
# show-clock=Whether to show the clock in the menubar (true or false)
# show-quit=Whether to show the quit menu in the menubar (true or false)
# logo=Logo file to use
# other-monitors-logo=Logo file to use for other monitors
# theme-name=GTK+ theme to use
# icon-theme-name=Icon theme to use
# font-name=Font to use
# xft-antialias=Whether to antialias Xft fonts (true or false)
# xft-dpi=Resolution for Xft in dots per inch
# xft-hintstyle=What degree of hinting to use (hintnone/hintslight/hintmedium/hintfull)
# xft-rgba=Type of subpixel antialiasing (none/rgb/bgr/vrgb/vbgr)
# onscreen-keyboard=Whether to enable the onscreen keyboard (true or false)
# high-contrast=Whether to use a high contrast theme (true or false)
# screen-reader=Whether to enable the screen reader (true or false)
# play-ready-sound=A sound file to play when the greeter is ready
# hidden-users=List of usernames (separated by semicolons) that are hidden until Ctr+Alt+Shift is pressed
# group-filter=List of groups that users must be part of to be shown (empty list shows all users)
# enable-hidpi=Whether to enable HiDPI support (on/off/auto)
# only-on-monitor=Sets the monitor on which to show the login window, -1 means "follow the mouse"
# stretch-background-across-monitors=Whether to stretch the background across multiple monitors (false by default)
# clock-format=What clock format to use (e.g., %H:%M or %l:%M %p)
```

#### Bonus: Removing the dotted grid in the Login Screen

set `draw-grid` to `false`

### Hiding the `select boot` screen on `EndeavourOS`

Run the following command

```zsh
sudo nano /etc/default/grub
```

Look for: `GRUB_TIMEOUT=5` and set it to `0`
Then run the following command to `remake` the config

```zsh
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

## How to fix gitub error related to : `The name org.freedesktop.secrets was not provided by any .service files`

Run the following command:

```zsh
sudo pacman -S gnome-keyring libsecret
```

## Check battery status of laptop

Lets first check the devices using `upower` with:

```zsh
upower -e
```

Then:

```zsh
upower -i /org/freedesktop/UPower/devices/battery_CMB0
```

Where `battery_CMB0` is your battery

## Get full hardware info:

```zsh
inxi -Fxz
```

## Using i3lock-color rather than the default installed i3lock

### `IMPORTANT!!`

Uninstall `i3lock` first as it will conflict with `i3lock-color`

```zsh
sudo pacman -R i3lock
```

Install `i3lock-color`

```zsh
yay i3lock-color
```

OPTIONAL: if you a have not yet set for the `lock` config under `~/.config/i3/scripts/` execute the following to run

```zsh
sudo chmod +x ~/.config/i3/scripts/lock
```

# Mouse Accelartion and Sensitivity

Run the command to edit the acceleration and sensitivity

`sudo vim /usr/share/X11/xorg.conf.d/40-libinput.conf`

Look for the section `InputClass` with Identifier `libinput pointer catchall`

Add the following below:

```zsh
        Option "AccelProfile" "flat"  #disable mouse accelaration
        Option "AccelSpeed" "-0.5"    #mouse speed beteen -1 and 1
```

# Spotify Theme

Install `spicetify`

```zsh
yay -S spicetify-cli
```

Download themes

```zsh
git clone --depth=1 https://github.com/spicetify/spicetify-themes.git
```

Copy the files to the themes folder

```zsh
cd spicetify-themes
```

then

```zsh
cp -r * ~/.config/spicetify/Themes
```

Choose which theme to apply just by running:

```bash
spicetify config current_theme THEME_NAME
```

Some themes have 2 or more different color schemes. After selecting the theme you can switch between them with:

```bash
spicetify config color_scheme SCHEME_NAME
```

# Cava audio visualizer

Install `cava`

```zsh
pacman -S base-devel fftw alsa-lib iniparser pulseaudio autoconf-archive pkgconf
```

Get the themes from [catppuccin cava](https://github.com/catppuccin/cava)

1. Choose your flavor.
2. Choose your background variant: opaque or transparent.
3. Copy the contents of `themes/<flavor>.cava` or `themes/<flavor>-transparent.cava` into your Cava config file (usually located at: `$HOME/.config/cava/`), replacing the existing gradient settings.
4. Reload cava if it was already playing.

# xfce4-terminal color schemes

Get the themes from [catppuccin xfce4-terminal](https://github.com/catppuccin/xfce4-terminal)

1. Download and move your flavor of choice from [`themes/`](./themes/) to `~/.local/share/xfce4/terminal/colorschemes`.
2. Open Xfce Terminal and go to **Preferences** > **Colors** > **Presets**.
3. Choose your flavor in the dropdown.

# spotify-player

Read docs [here](https://github.com/aome510/spotify-player)

We need cargo first, which comes in with rust:

```zsh
pacman -S rust
```

Then using `cargo` install `spotify-player`

```zsh
cargo install spotify_player --no-default-features --features pulseaudio-backend,media-control,streaming
```

The above method installs the essentials with out the `image` feature which loads the album art in the player

# Configure SSH for github

Generate `ssh` keys and add them to you github account, you can follow this [guide](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent)

Next is to update your `config` file for ssh under `~/.ssh/config` with something like this:

```zsh
#ecabigting
Host ecabigting.github.com #alias to the host
HostName github.com #actual host name
PreferredAuthentications publickey #specify to use public keys
IdentityFile ~/.ssh/id_xxxx #path to the key
User ecabigting #specify your username

#jonsnow
Host jonsnow.github.com
HostName github.com
PreferredAuthentications publickey
IdentityFile ~/.ssh/id_xxx2
User jonsnow
```

The `config` above enables you have multiple github `ssh` keys configured in the same machine

> IMPORTANT!
> To use a specific key when cloning a repo use the alias on the `SSH` clone link

For example if you are trying to clone `git@github.com:ecabigting/archlinux-configs.git` using `git clone` you need to use `git@ecabigting.github.com:ecabigting/archlinux-configs.git` to tell git to use the keys specificied under the host `ecabigting.github.com`

### autostart `ssh-agent` from `~/.bashrc` or `~/.zshrc`

```zsh
# auto start SSH agent
if ! pgrep -u "$USER" ssh-agent > /dev/null; then
    ssh-agent -t 1h > "$XDG_RUNTIME_DIR/ssh-agent.env"
fi
if [[ ! -f "$SSH_AUTH_SOCK" ]]; then
    source "$XDG_RUNTIME_DIR/ssh-agent.env" >/dev/null
fi
```

Adding the above code to your profile will when launch your terminal

### Some useful commands to remember

`ssh-add -l` to list all added keys to the agent
`ssh -T git@ecabigting.github.com` to test the alias added in the `.ssh/config` if its working

# OS clipboard access with Neovim

Inside Neovim run this command `:checkhealth` and scroll down to the `clipboard` section.

For arch linux, easier to install `xclip` with `pacman -S xclip` then set the clipboard default in your `~/.config/nvim/init.lua` by adding this line `vim.opt.clipboard = "unnamedplus"`

### yt-dlp
Install for windows via [winutil](https://github.com/ChrisTitusTech/winutil)

Install for Arch via pacman:
```zsh
sudo pacmang -S yt-dlp
```
For config copy the `yt-dlp` folder to the following location:

For windows:
`C:\Users\user\AppData\Roaming`

For Arch:
`.config/`
