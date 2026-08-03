module.exports = {
  testDir: "./tests/e2e",
  use: { baseURL: "http://127.0.0.1:8931" },
  webServer: {
    command: "node tools/serve.js tmp-e2e 8931",
    port: 8931,
    reuseExistingServer: true,
  },
};
