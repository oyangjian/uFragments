module.exports = {
  networks: {
    mainnet: {
      // Don't put your private key here:
    },
    compilers: {
      solc: {
        version: '0.4.25',
        settings: {
          optimizer: {
            enabled: true
          }
        }
      }
    }
  }
}
