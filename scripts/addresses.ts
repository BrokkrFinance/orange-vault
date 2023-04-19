import env from "hardhat";

export const getAddresses = () => {
  switch (env.network.name) {
    case "goerli":
      return {
        Deployer: "0xe66ffFd2D3aDE2697B3Cbeb69877a1fFE8A1f275",
        UniswapFactory: "0x1F98431c8aD98523631AE4a59f267346ea31F984",
        // Weth: "0x6E8EDc17Ef3db5f3Fbb7B8f6574934bD169E22E7",
        // Usdc: "0xCc0a1e7086eD38a701dD8886C1AaAc1CC00dF71f",
        // AavePool: "0x1Fe749bef290c350e85cC7BF29B228344355E52D",
        // VDebtWeth: "0x2Bb51435e2fd8d5FA43ef5287821D01faA01f1f8",
        // AUsdc: "0xe822F2c0AF9be5B11EDeEd50e617B572567b67E0",
        // UniswapPool: "0x5D5c8Aa7E4Df82D5f5e33b77c39524EBbc8988bF",
        // OrangeAlphaVault: "0x65b0661C10eA4beC7Dd9EbF578e6B6ac27b6f82F",
        // UniswapV3PoolAccessorMock: "0xABEcB921FbA87F8157dD7c070FF797352f38Ee79",
        LiquidityAmountsMock: "0x884B0F4c8c23D4d8Fd095B24879aaE6461b32475",
        // GelatoMock: "0x2461B62c06500C0256c324f57d4b71F9A5557e16",
        Weth: "0x246ce443416fd4cc9C057C99cA0918F4d3d525d4",
        Usdc: "0xc24e97F0B049C6D1EC2Ddb21f2f55C128f74412c",
        AavePool: "0x0a4eDC8A76776468311F3f58a6B6cf4c3DC6e287",
        VDebtWeth: "0x0d63c72e6F356f42D1940352F6eDD4f983E54CaD",
        AUsdc: "0x71c5271dCda234A1acA574f490C87e087A108E71",
        // UniswapPool: "0x566C69144Cfa02d0406635844488dD5BCF7c52a0", // 0.3%
        UniswapPool: "0xC31E54c7a869B9FcBEcc14363CF510d1c41fa443", // 0.05%
        UniswapV3PoolAccessorMock: "0xF195B1Df7c20a4F266366dE4Fc3e95cD40d717bF",
        OrangeAlphaVault: "0x863EE7dBc5F96e1c91aB94914194c21cD7A2eEd6",
      };
    case "arb":
      return {
        Deployer: "0xe66ffFd2D3aDE2697B3Cbeb69877a1fFE8A1f275",
        Weth: "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1",
        Usdc: "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8",
        AavePool: "0x794a61358D6845594F94dc1DB02A252b5b4814aD",
        VDebtWeth: "0x0c84331e39d6658Cd6e6b9ba04736cC4c4734351",
        AUsdc: "0x625E7708f30cA75bfd92586e17077590C60eb4cD",
        UniswapPool: "0xC31E54c7a869B9FcBEcc14363CF510d1c41fa443", // 0.05%
        UniswapRouter: "0xE592427A0AEce92De3Edee1F18E0157C05861564",
        GelatoOps: "",
        SafeAavePool: "",
        UniswapV3Twap: "",
        OrangeAlphaParameters: "",
        OrangeAlphaVault: "",
        OrangeAlphaPeriphery: "",
        OrangeAlphaResolver: "",
      };
  }
};
