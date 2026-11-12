FROM archlinux:latest

# Install system dependencies for waybar icon testing
# - grim: Wayland screenshot tool (perception layer)
# - hyprland: provides hyprctl for monitor geometry
# - python + test deps: pytest runner
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm \
        grim \
        hyprland \
        python \
        python-pytest \
        python-pillow \
    && pacman -Scc --noconfirm

# Copy custom waybar module scripts into container
COPY scripts/ /opt/waybar-scripts/
RUN chmod +x /opt/waybar-scripts/*
ENV PATH="/opt/waybar-scripts:$PATH"

# Create non-root user matching host UID for Wayland socket permissions
ARG UID=1000
RUN useradd -m -u $UID testrunner
USER testrunner

WORKDIR /tests
ENTRYPOINT ["pytest"]
CMD ["-v", "--tb=short"]
