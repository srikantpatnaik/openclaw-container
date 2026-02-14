# Build instructions:

# 1. Build the Docker image:
#    docker build -t aihost .

# 2. Run the container with SSH key mounting:
#    docker run -d \
#      --name aihost \
#      --hostname aihost \
#      -p 2222:22 \
#      -v ~/.ssh:/home/aiuser/.ssh:ro \
#      -v ~/.gitconfig:/home/aiuser/.gitconfig:ro \
#      -v ~/.git-credentials:/home/aiuser/.git-credentials:ro \
#      aihost

# 3. Alternatively, using docker-compose:
#    docker-compose up -d

# Note: Ensure your SSH keys are properly configured and have the right permissions
# (chmod 600 for private keys, 644 for public keys).