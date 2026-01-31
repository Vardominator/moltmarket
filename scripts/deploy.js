const hre = require("hardhat");

async function main() {
  // Fee recipient address (Varderes)
  const FEE_RECIPIENT = "0x5FA9B310585204790C42A26953b3a8cd2Fa36C3F";
  
  console.log("Deploying MoltMarket...");
  console.log("Fee recipient:", FEE_RECIPIENT);
  
  // Get current gas price
  const feeData = await hre.ethers.provider.getFeeData();
  console.log("Gas price:", hre.ethers.formatUnits(feeData.gasPrice, "gwei"), "gwei");
  
  const MoltMarket = await hre.ethers.getContractFactory("MoltMarket");
  const market = await MoltMarket.deploy(FEE_RECIPIENT, {
    gasLimit: 3000000  // 3M gas limit for deployment
  });
  
  await market.waitForDeployment();
  
  const address = await market.getAddress();
  console.log("MoltMarket deployed to:", address);
  
  // Log initial settings
  const feePercent = await market.feePercent();
  console.log("Initial fee:", feePercent.toString(), "basis points (", Number(feePercent) / 100, "%)");
  
  // Verify on Etherscan (if API key provided)
  if (process.env.ETHERSCAN_API_KEY) {
    console.log("Waiting for block confirmations...");
    await market.deploymentTransaction().wait(5);
    
    console.log("Verifying on Etherscan...");
    await hre.run("verify:verify", {
      address: address,
      constructorArguments: [FEE_RECIPIENT],
    });
  }
  
  return address;
}

main()
  .then((address) => {
    console.log("\n✅ Deployment complete!");
    console.log("Contract address:", address);
    process.exit(0);
  })
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
