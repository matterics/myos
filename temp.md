
Resume this session with:o read, edit, and execute files here.
claude --resume 86079292-b7bf-4538-a2fe-4f4e6a04cf39



wsl -e bash -lc "cd /mnt/c/Users/harsh/Documents/MyOS && docker run --rm --privileged -v /mnt/c/Users/harsh/Documents/MyOS:/src -v \$HOME/.ollama:/root/.ollama_host -v myos-pacman-cache:/var/cache/pacman/pkg -w /src myos-build bash ./scripts/build-iso.sh"



wsl -e bash -lc "docker run --rm -v /mnt/c/Users/harsh/Documents/MyOS:/src -w /src/shell -u builder myos-build bash -c 'git config --global --add safe.directory /home/builder/flutter && flutter pub get >/dev/null && flutter analyze && flutter test' 2>&1 | tail -3"