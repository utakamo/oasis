#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define SOCKET_PATH "/tmp/springd.sock"
#define BUFFER_SIZE 256

void send_message(const char *message) {
    int sockfd;
    struct sockaddr_un addr;
    char buffer[BUFFER_SIZE];

    // Create socket
    sockfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sockfd == -1) {
        perror("socket");
        exit(EXIT_FAILURE);
    }

    // Set up the address structure
    memset(&addr, 0, sizeof(struct sockaddr_un));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCKET_PATH, sizeof(addr.sun_path) - 1);

    // Connect to the server
    if (connect(sockfd, (struct sockaddr *)&addr, sizeof(struct sockaddr_un)) == -1) {
        perror("connect");
        close(sockfd);
        exit(EXIT_FAILURE);
    }

    // Send the message
    if (write(sockfd, message, strlen(message)) == -1) {
        perror("write");
        close(sockfd);
        exit(EXIT_FAILURE);
    }

    // Receive response (optional)
    ssize_t num_bytes = read(sockfd, buffer, BUFFER_SIZE - 1);
    if (num_bytes > 0) {
        buffer[num_bytes] = '\0';
        printf("Response: %s\n", buffer);
    } else if (num_bytes == -1) {
        perror("read");
    }

    // Close the socket
    close(sockfd);
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <command>\n", argv[0]);
        exit(EXIT_FAILURE);
    }

    // Combine all arguments into a single command string
    char command[BUFFER_SIZE] = {0};
    for (int i = 1; i < argc; i++) {
        strncat(command, argv[i], BUFFER_SIZE - strlen(command) - 1);
        if (i < argc - 1) {
            strncat(command, " ", BUFFER_SIZE - strlen(command) - 1);
        }
    }

    send_message(command);

    return 0;
}
