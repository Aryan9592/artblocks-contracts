import { ethers } from "hardhat";
import { RandomizerCryptoCitizens__factory } from "../../contracts/factories/RandomizerCryptoCitizens__factory";
import { GenArt721CoreV2CryptoCitizens__factory } from "../../contracts/factories/GenArt721CoreV2CryptoCitizens__factory";
import { GenArt721MinterCryptoCitizens__factory } from "../../contracts/factories/GenArt721MinterCryptoCitizens__factory";

//////////////////////////////////////////////////////////////////////////////
// CONFIG BEGINS HERE
//////////////////////////////////////////////////////////////////////////////
const pbabTokenName = "CryptoCitizens";
const pbabTokenTicker = "CITIZEN";
const pbabTransferAddress = "0xB96E81f80b3AEEf65CB6d0E280b15FD5DBE71937";
const rendererProviderAddress = "0xE79e97c3e7990672c3D45c46714eF748dd0EA7df";
//////////////////////////////////////////////////////////////////////////////
// CONFIG ENDS HERE
//////////////////////////////////////////////////////////////////////////////

async function main() {
  const [deployer] = await ethers.getSigners();

  //////////////////////////////////////////////////////////////////////////////
  // DEPLOYMENT BEGINS HERE
  //////////////////////////////////////////////////////////////////////////////

  // Deploy Randomizer contract.
  const randomizerFactory = new RandomizerCryptoCitizens__factory(deployer);
  const randomizer = await randomizerFactory.deploy();

  await randomizer.deployed();
  console.log(`Randomizer deployed at ${randomizer.address}`);

  // Deploy Core contract.
  const genArt721CoreFactory = new GenArt721CoreV2CryptoCitizens__factory(
    deployer
  );
  const genArt721Core = await genArt721CoreFactory.deploy(
    pbabTokenName,
    pbabTokenTicker,
    randomizer.address
  );

  await genArt721Core.deployed();
  console.log(`GenArt721Core deployed at ${genArt721Core.address}`);

  // Deploy Minter contract.
  const genArt721MinterFactory = new GenArt721MinterCryptoCitizens__factory(
    deployer
  );
  const genArt721Minter = await genArt721MinterFactory.deploy(
    genArt721Core.address
  );

  await genArt721Minter.deployed();
  console.log(`Minter deployed at ${genArt721Minter.address}`);

  //////////////////////////////////////////////////////////////////////////////
  // DEPLOYMENT ENDS HERE
  //////////////////////////////////////////////////////////////////////////////

  //////////////////////////////////////////////////////////////////////////////
  // SETUP BEGINS HERE
  //////////////////////////////////////////////////////////////////////////////

  // Allowlist the Minter on the Core contract.
  await genArt721Core
    .connect(deployer)
    .addMintWhitelisted(genArt721Minter.address);
  console.log(`Allowlisted the Minter on the Core contract.`);

  // Update the Renderer provider.
  await genArt721Core
    .connect(deployer)
    .updateRenderProviderAddress(rendererProviderAddress);
  console.log(`Updated the renderer provider to: ${rendererProviderAddress}.`);

  // Set Minter owner.
  await genArt721Minter.connect(deployer).setOwnerAddress(pbabTransferAddress);
  console.log(`Set the Minter owner to: ${pbabTransferAddress}.`);

  // Allowlist AB staff (testnet only)
  const network = await ethers.provider.getNetwork();
  if (network.name == "ropsten") {
    // purplehat
    await genArt721Core
      .connect(deployer)
      .addWhitelisted("0xB8559AF91377e5BaB052A4E9a5088cB65a9a4d63");
    // dogbot
    await genArt721Core
      .connect(deployer)
      .addWhitelisted("0x3c3cAb03C83E48e2E773ef5FC86F52aD2B15a5b0");
    // ben_thank_you
    await genArt721Core
      .connect(deployer)
      .addWhitelisted("0x0B7917b62BC98967e06e80EFBa9aBcAcCF3d4928");
    console.log(`Performing ${network.name} deployment, allowlisted AB staff.`);
  }

  // Allowlist new PBAB owner.
  await genArt721Core.connect(deployer).addWhitelisted(pbabTransferAddress);
  console.log(`Allowlisted Core contract access for: ${pbabTransferAddress}.`);

  // Transfer Core contract to new PBAB owner.
  await genArt721Core.connect(deployer).updateAdmin(pbabTransferAddress);
  console.log(`Transferred Core contract admin to: ${pbabTransferAddress}.`);

  // Output instructions for manual Etherscan verification.
  const standardVerify =
    "yarn hardhat verify --contract <path to .sol>:<contract name>";
  console.log(`Verify GenArt721CoreV2 deployment with:`);
  console.log(
    `${standardVerify} --network ${network.name} ${genArt721Core.address} "${pbabTokenName}" "${pbabTokenTicker}" ${randomizer.address}`
  );
  console.log(`Verify GenArt721Minter deployment with:`);
  console.log(
    `${standardVerify} --network ${network.name} ${genArt721Minter.address} ${genArt721Core.address}`
  );

  //////////////////////////////////////////////////////////////////////////////
  // SETUP ENDS HERE
  //////////////////////////////////////////////////////////////////////////////
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
