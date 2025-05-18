# Source the original .bashrc if it exists
if [ -f /etc/bash.bashrc ]; then
    . /etc/bash.bashrc
fi

# Custom prompt configuration
PS1='\[\033[01;32m\][ubuntuweb83 \[\033[01;34m\]\W\[\033[01;32m\]]# \[\033[00m\]'


# Additional customizations
alias ll='ls -la'
alias l='ls -l'
