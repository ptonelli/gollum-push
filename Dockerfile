FROM alpine/git:v2.49.1

RUN apk add --no-cache inotify-tools

# Use the same UID/GID as Gollum for compatibility
ARG UID=1000
ARG GID=1000

# Create git user with same UID/GID as Gollum's www-data
RUN addgroup -g $GID git && \
    adduser -D -u $UID -G git git

# Set up SSH configuration directory for the git user
RUN mkdir -p /home/git/.ssh && \
    chmod 700 /home/git/.ssh && \
    chown -R git:git /home/git

# Copy our backup script
COPY git-backup.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/git-backup.sh

# Set the safe.directory for the git user to allow operations in the wiki directory
RUN git config --file /home/git/.gitconfig --add safe.directory /wiki && \
    chown git:git /home/git/.gitconfig

# Switch to git user
USER git

# Set up git identity (customize these values)
RUN git config --global user.name "Wiki Backup" && \
    git config --global user.email "wiki-backup@example.com"

# Entry point script
ENTRYPOINT ["/usr/local/bin/git-backup.sh"]
