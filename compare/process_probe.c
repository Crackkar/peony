/* Launch one CLI program and record its process lifetime and peak resident set.
   Program stdout/stderr pass through unchanged to the calling harness. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <psapi.h>
#include <shellapi.h>
#include <wchar.h>

static wchar_t *command_line(int count, wchar_t **arguments) {
    size_t capacity = 1;
    for (int i = 3; i < count; ++i) capacity += 2 * wcslen(arguments[i]) + 4;
    wchar_t *text = calloc(capacity, sizeof(wchar_t));
    if (!text) return NULL;
    size_t used = 0;
    for (int i = 3; i < count; ++i) {
        if (i != 3) text[used++] = L' ';
        text[used++] = L'"';
        const wchar_t *argument = arguments[i];
        while (*argument) {
            size_t slashes = 0;
            while (argument[slashes] == L'\\') ++slashes;
            argument += slashes;
            if (*argument == L'"') {
                for (size_t j = 0; j < slashes * 2 + 1; ++j) text[used++] = L'\\';
                text[used++] = *argument++;
            } else if (*argument == 0) {
                for (size_t j = 0; j < slashes * 2; ++j) text[used++] = L'\\';
            } else {
                for (size_t j = 0; j < slashes; ++j) text[used++] = L'\\';
                text[used++] = *argument++;
            }
        }
        text[used++] = L'"';
    }
    text[used] = 0;
    return text;
}

static HANDLE inherited_standard(DWORD number) {
    HANDLE source = GetStdHandle(number);
    HANDLE copied = NULL;
    if (source && source != INVALID_HANDLE_VALUE) {
        DuplicateHandle(GetCurrentProcess(), source, GetCurrentProcess(), &copied,
                        0, TRUE, DUPLICATE_SAME_ACCESS);
    }
    return copied;
}

int main(void) {
    int count = 0;
    wchar_t **arguments = CommandLineToArgvW(GetCommandLineW(), &count);
    if (!arguments || count < 4) return 2;
    unsigned long timeout_ms = wcstoul(arguments[2], NULL, 10);
    wchar_t *command = command_line(count, arguments);
    if (!command) return 2;
    STARTUPINFOW startup = {0};
    PROCESS_INFORMATION child = {0};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = inherited_standard(STD_INPUT_HANDLE);
    startup.hStdOutput = inherited_standard(STD_OUTPUT_HANDLE);
    startup.hStdError = inherited_standard(STD_ERROR_HANDLE);
    LARGE_INTEGER frequency, start, end;
    QueryPerformanceFrequency(&frequency);
    QueryPerformanceCounter(&start);
    ULONGLONG start_ticks = GetTickCount64();
    BOOL created = CreateProcessW(NULL, command, NULL, NULL, TRUE,
                                  CREATE_NO_WINDOW, NULL, NULL, &startup, &child);
    if (startup.hStdInput) CloseHandle(startup.hStdInput);
    if (startup.hStdOutput) CloseHandle(startup.hStdOutput);
    if (startup.hStdError) CloseHandle(startup.hStdError);
    free(command);
    if (!created) {
        fprintf(stderr, "process probe: CreateProcessW failed: %lu\n", GetLastError());
        LocalFree(arguments);
        return 2;
    }
    size_t peak = 0;
    int timed_out = 0;
    for (;;) {
        PROCESS_MEMORY_COUNTERS counters = {0};
        counters.cb = sizeof(counters);
        if (GetProcessMemoryInfo(child.hProcess, &counters, sizeof(counters)) &&
            counters.PeakWorkingSetSize > peak) peak = counters.PeakWorkingSetSize;
        DWORD state = WaitForSingleObject(child.hProcess, 1);
        if (state == WAIT_OBJECT_0) break;
        if (state != WAIT_TIMEOUT) break;
        if (timeout_ms && GetTickCount64() - start_ticks >= timeout_ms) {
            timed_out = 1;
            TerminateProcess(child.hProcess, 124);
            WaitForSingleObject(child.hProcess, INFINITE);
            break;
        }
    }
    QueryPerformanceCounter(&end);
    PROCESS_MEMORY_COUNTERS counters = {0};
    counters.cb = sizeof(counters);
    if (GetProcessMemoryInfo(child.hProcess, &counters, sizeof(counters)) &&
        counters.PeakWorkingSetSize > peak) peak = counters.PeakWorkingSetSize;
    DWORD exit_code = 0;
    GetExitCodeProcess(child.hProcess, &exit_code);
    CloseHandle(child.hThread);
    CloseHandle(child.hProcess);
    FILE *report = _wfopen(arguments[1], L"wb");
    if (!report) {
        LocalFree(arguments);
        return 2;
    }
    unsigned long long elapsed_ns = (unsigned long long)
        ((double)(end.QuadPart - start.QuadPart) * 1000000000.0 / frequency.QuadPart);
    fprintf(report, "{\"elapsed_ns\":%llu,\"peak_rss_bytes\":%llu,\"exit_code\":%lu,\"timed_out\":%s}\n",
            elapsed_ns, (unsigned long long)peak, exit_code, timed_out ? "true" : "false");
    fclose(report);
    LocalFree(arguments);
    return 0;
}

#else
#include <errno.h>
#include <signal.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static uint64_t nanoseconds(struct timespec time) {
    return (uint64_t)time.tv_sec * 1000000000ull + (uint64_t)time.tv_nsec;
}

int main(int count, char **arguments) {
    if (count < 4) return 2;
    unsigned long timeout_ms = strtoul(arguments[2], NULL, 10);
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    pid_t child = fork();
    if (child == -1) return 2;
    if (child == 0) {
        execvp(arguments[3], arguments + 3);
        fprintf(stderr, "process probe: exec failed: %s\n", strerror(errno));
        _exit(127);
    }
    struct rusage usage = {0};
    int status = 0;
    int timed_out = 0;
    struct timespec pause = {0, 1000000};
    for (;;) {
        pid_t result = wait4(child, &status, WNOHANG, &usage);
        if (result == child) break;
        if (result == -1) return 2;
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (timeout_ms && nanoseconds(now) - nanoseconds(start) >= (uint64_t)timeout_ms * 1000000ull) {
            timed_out = 1;
            kill(child, SIGKILL);
            if (wait4(child, &status, 0, &usage) == -1) return 2;
            break;
        }
        nanosleep(&pause, NULL);
    }
    clock_gettime(CLOCK_MONOTONIC, &end);
#ifdef __APPLE__
    unsigned long long peak = (unsigned long long)usage.ru_maxrss;
#else
    unsigned long long peak = (unsigned long long)usage.ru_maxrss * 1024ull;
#endif
    int exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    FILE *report = fopen(arguments[1], "wb");
    if (!report) return 2;
    fprintf(report, "{\"elapsed_ns\":%llu,\"peak_rss_bytes\":%llu,\"exit_code\":%d,\"timed_out\":%s}\n",
            (unsigned long long)(nanoseconds(end) - nanoseconds(start)), peak,
            exit_code, timed_out ? "true" : "false");
    fclose(report);
    return 0;
}
#endif
