# Shared Flutter & Dart Pub Cache Configuration

This guide provides the instructions to configure a centralized, robust `pub-cache` for a Linux
environment acting as both a local development workstation and a Dagger CI runner.


The `pub-cache` is the local directory where Dart and Flutter store downloaded packages
(dependencies) fetched from `pub.dev` or other package repositories. By default, it resides in
`~/.pub-cache` (or `~/.local/share/pub-cache` on some Linux setups) for each individual user. When
multiple users or CI runners operate on the same machine, they end up downloading the same packages
redundantly, wasting disk space and network bandwidth.

This setup aggressively prevents permission drift between local user accounts and CI service
accounts. It also strictly forbids `pub global activate` via OS-level directory permissions to
guarantee a 100% collision-free environment, effectively forcing
roject-level dependency
management.

---

## Prerequisites
- Root (`sudo`) access to the Linux host machine.
- The `acl` package installed (standard on most modern distributions like Ubuntu).

## Step 1: Create the Dedicated Group and Directory
Establish a shared user group for all human developers and CI service accounts, and provision the
central cache directory.

```bash
# Create the shared group
sudo groupadd flutter-devs

# Add your local user to the group
sudo usermod -aG flutter-devs $USER

# Add the CI runner service account to the group (e.g., 'dagger' or 'gitlab-runner')
# sudo usermod -aG flutter-devs <ci-service-user>

# Create the centralized cache directory in /opt
sudo mkdir -p /opt/pub-cache
sudo chown root:flutter-devs /opt/pub-cache


Step 2: Enforce Strict Group Permissions (ACLs)
Standard Linux permissions result in the creator of a file owning it exclusively. To prevent permission drift when Dagger or the local user pulls dependencies, apply Access Control Lists (ACLs). This forces all newly created subdirectories and files to inherit read, write, and execute permissions for the flutter-devs group.

Bash


# Set the SetGID bit so new files inherit the 'flutter-devs' group
sudo chmod 2775 /opt/pub-cache

# Apply default ACLs to enforce rwx for the group on all future files/folders
sudo setfacl -d -m g:flutter-devs:rwx /opt/pub-cache

# Apply the same ACLs to the directory itself immediately
sudo setfacl -m g:flutter-devs:rwx /opt/pub-cache


Step 3: Export the Environment Variable
You must instruct Dart and Flutter to utilize this central location instead of the default ~/.pub-cache.
A. Global Host Setup
For system-wide application, drop an environment script into /etc/profile.d/.

Bash


echo 'export PUB_CACHE=/opt/pub-cache' | sudo tee /etc/profile.d/flutter-pub-cache.sh
echo 'export PATH="$PATH:$PUB_CACHE/bin"' | sudo tee -a /etc/profile.d/flutter-pub-cache.sh


(Note: Users will need to log out and log back in, or source the profile, for this to take effect).
B. Dagger Pipeline Integration (Go SDK)
When writing your Dagger pipeline controller, mount the host directory directly into the container so the CI runner uses the identical cache pool:

Go


// In your Dagger CI logic, mount the shared host cache into the container
WithMountedDirectory("/root/.pub-cache", dag.Host().Directory("/opt/pub-cache")).
WithEnvVariable("PUB_CACHE", "/root/.pub-cache")


Step 4: The 100% Strict Lockdown for Global Activations
Running dart pub global activate <package> in a shared cache causes severe conflicts by overwriting global executables. To guarantee this never happens, we revoke write access to the specific global activation subdirectories.
By implementing this OS-level constraint, any attempt to globally activate a package—regardless of multiline bash scripts, variables, or clever aliases—will be unconditionally rejected by the Linux kernel with a Permission denied error. Standard pub get commands for project dependencies will continue working without issue.

Bash


# Ensure the target subdirectories exist
sudo mkdir -p /opt/pub-cache/bin
sudo mkdir -p /opt/pub-cache/global_packages

# Change ownership of exclusively these two directories to root
sudo chown root:root /opt/pub-cache/bin
sudo chown root:root /opt/pub-cache/global_packages

# Remove write permissions for everyone else
sudo chmod 755 /opt/pub-cache/bin
sudo chmod 755 /opt/pub-cache/global_packages


Developer Workflow Impact
Because global activations are now entirely disabled on this host, developers and CI scripts must manage CLI tools locally.
If a tool like melos, slidy, or coverage is required:
Add it to the dev_dependencies of your pubspec.yaml.
Invoke it project-locally using dart run <package_name>.
