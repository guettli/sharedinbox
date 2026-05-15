# Development Environment Setup

This document explains how to set up a development environment for SharedInbox.

## ⚠️ Security Recommendation: Use a Dedicated Linux User

For enhanced security, especially when working with autonomous coding agents (like Gemini CLI in YOLO mode), we **strongly recommend** using a dedicated Linux user for this project. This isolates the project environment and prevents any potential accidental damage to your main system.

### 1. Create a Dedicated User

Set the user name variable (default is `si` for SharedInbox):

```bash
export DEV_USER=si
```

Create the user and add them to the `sudo` group:

```bash
sudo adduser --disabled-password newuser $DEV_USER
```

Set up SSH public key login (replace with your actual public key):

```bash
sudo mkdir -p /home/$DEV_USER/.ssh
sudo chmod 700 /home/$DEV_USER/.ssh
echo "ssh-ed25519 AAAA... your-key-comment" | sudo tee /home/$DEV_USER/.ssh/authorized_keys
sudo chmod 600 /home/$DEV_USER/.ssh/authorized_keys
sudo chown -R $DEV_USER:$DEV_USER /home/$DEV_USER/.ssh
```

### 2. Switch to the Dedicated User

```bash
ssh $DEV_USER@localhost
```

### Create ssh-keypair

```bash
ssh-keygen
```

### 3. Clone the Repository

Clone the project into your new user's home directory:

```bash^
git clone ssh://git@codeberg.org/guettli/sharedinbox.git

# Move git directory into $HOME
# This user only works on the git repo. Avoid "cd sharedinbox" after each login...
mv sharedinbox/* .
mv sharedinbox/.??* .
rmdir sharedinbox/
```

### 3b. Configure Git Identity

The new user needs a Git identity for commits and some scripts:

```bash
git config --global user.name "Your Name"
git config --global user.email "your.email@example.com"
```

### 4. Install System Dependencies

This project uses **Nix** with flakes to manage its toolchain (Flutter, Dart, Stalwart, etc.).

```
mkdir -p .config/nix

echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf

nix profile add nixpkgs#direnv

nix profile add nixpkgs#nix-direnv

echo 'eval "$(direnv hook bash)"' >> ~/.bashrc
source ~/.bashrc

.config/direnv/direnv.toml
```
[global]
hide_env_diff = true
#log_filter = "^$"

[whitelist]
   prefix = [ "/home/DEV_USER-CHANGE_THAT" ]
```



    ### 4b. Additional Permissions (GUI & Android)

    1.  **GUI Access**: To run the Linux app (`task run`) from the `si` user, you must allow it to access your X server. Run this **from your main user terminal**:
        ```bash
        xhost +local:$DEV_USER
        ```

    2.  **Android Emulator (KVM)**: If you plan to use the Android emulator, add the user to the `kvm` group:
        ```bash
        sudo usermod -aG kvm $DEV_USER
        ```

    ### 5. Project Setup

    Once you are in the project directory and have the dependencies installed:

    1.  **Initialize Environment**:
        ```bash
        cp .env.example .env
        ```

    2.  **Allow direnv**:
        ```bash
        direnv allow
        ```
        *This will trigger Nix to download and set up the environment (Flutter, Android SDK, etc.). It might take some time on the first run.*

    3.  **Install Flutter (via FVM)**:
        Nix provides FVM, which manages the pinned Flutter version.
        ```bash
        fvm install
        ```

    4.  **Initial Setup**:
        Run the comprehensive setup command which handles `pub get`, code generation, and git hooks:
        ```bash
        task setup
        ```

### 6. Verify the Setup

Run the full check suite to ensure everything is working correctly:

```bash
task check
```

### 7. Running the App

To run the app on your Linux desktop:

```bash
task run
```

---

## Working with VS Code

To maintain isolation, it is recommended to run VS Code "remotely" on the dedicated development user.

### Preferred Method: VS Code Remote - SSH

The most robust way to work with a separate user is using the **VS Code Remote - SSH** extension. This allows you to run the VS Code Server as the `si` user while using your main user's GUI.

1.  **Install the Extension**: Install "Remote - SSH" from the VS Code Marketplace.
2.  **Enable SSH for the Dev User**:
    From your main user, copy your SSH public key to the dev user:
    ```bash
    # As your main user:
    sudo mkdir -p /home/$DEV_USER/.ssh
    sudo cp ~/.ssh/id_rsa.pub /home/$DEV_USER/.ssh/authorized_keys
    sudo chown -R $DEV_USER:$DEV_USER /home/$DEV_USER/.ssh
    sudo chmod 700 /home/$DEV_USER/.ssh
    sudo chmod 600 /home/$DEV_USER/.ssh/authorized_keys
    ```
3.  **Connect**:
    In VS Code, open the Command Palette (`Ctrl+Shift+P`) and select `Remote-SSH: Connect to Host...`.
    Enter: `si@localhost` (or `$DEV_USER@localhost`).
4.  **Install Extensions in the Remote**:
    Once connected, you will need to install the following extensions *on the remote user*:
    *   **Dart** / **Flutter**
    *   **direnv**: (by mkhl) Highly recommended to automatically load the Nix environment inside VS Code.
    *   **Nix IDE**: For syntax highlighting.

### Why SSH?
Using SSH to `localhost` is preferred over complex X11/Wayland permission hacks. It provides a clean boundary for the VS Code process and any integrated terminal or coding agents, ensuring they cannot access your personal files in `/home/$YOUR_USER`.

> **Note on Security:** While these instructions add the user to the `sudo` group for convenience during setup, you can remove it later with `sudo gpasswd -d $DEV_USER sudo` to further restrict the user and any coding agents.

---

## Daily Workflow

Refer to the [README.md](./README.md#daily-workflow) for common development tasks and commands.
