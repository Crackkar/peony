const regex = @import("library_regex_tests");
const http = @import("library_http_tests");

test "regex syntax flags Unicode and bytes" {
    try regex.testRegexSyntaxFlagsUnicodeAndBytes();
}
test "regex ordered captures objects and positions" {
    try regex.testRegexOrderedCapturesObjectsAndPositions();
}
test "regex split sub templates escape and pattern methods" {
    try regex.testRegexSplitSubTemplatesEscapeAndPatternMethods();
}
test "regex callable replacement resumes input exactly once" {
    try regex.testRegexCallableReplacementResumesInputExactlyOnce();
}
test "regex work limit GC and reset" {
    try regex.testRegexWorkLimitGcAndReset();
}
test "urlopen response cursor context SSL and validation" {
    try http.testUrlopenResponseCursorContextSslAndValidation();
}
test "urlopen POST context manager and errors" {
    try http.testUrlopenPostContextManagerAndErrors();
}
test "requests query form headers encoding and JSON" {
    try http.testRequestsQueryFormHeadersEncodingAndJson();
}
test "requests status and transport exceptions" {
    try http.testRequestsStatusAndTransportExceptions();
}
test "time clock sleep validation and cancellation" {
    try http.testTimeClockSleepValidationAndCancellation();
}
test "SSLContext identity constructor and mutation" {
    try http.testSslContextTypeAndMutation();
}
test "host reply identity schema and size retain pending request" {
    try http.testHostReplyIdentitySchemaAndSizeDoNotConsumePendingRequest();
}
