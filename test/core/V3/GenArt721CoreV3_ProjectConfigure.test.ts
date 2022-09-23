import {
  BN,
  constants,
  expectEvent,
  expectRevert,
  balance,
  ether,
} from "@openzeppelin/test-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";

import {
  getAccounts,
  assignDefaultConstants,
  deployAndGet,
  deployCoreWithMinterFilter,
  mintProjectUntilRemaining,
  advanceEVMByTime,
} from "../../util/common";
import { FOUR_WEEKS } from "../../util/constants";
import {
  SQUIGGLE_SCRIPT,
  SKULPTUUR_SCRIPT_APPROX,
  CONTRACT_SIZE_LIMIT_SCRIPT,
  RANDOM_UTF_EIGHT_SCRIPT,
} from "../../util/example-scripts";

/**
 * Tests for V3 core dealing with configuring projects.
 */
describe("GenArt721CoreV3 Project Configure", async function () {
  beforeEach(async function () {
    // standard accounts and constants
    this.accounts = await getAccounts();
    await assignDefaultConstants.call(this);

    // deploy and configure minter filter and minter
    ({
      genArt721Core: this.genArt721Core,
      minterFilter: this.minterFilter,
      randomizer: this.randomizer,
      adminACL: this.adminACL,
    } = await deployCoreWithMinterFilter.call(
      this,
      "GenArt721CoreV3",
      "MinterFilterV1"
    ));

    this.minter = await deployAndGet.call(this, "MinterSetPriceV2", [
      this.genArt721Core.address,
      this.minterFilter.address,
    ]);

    // add project zero
    await this.genArt721Core
      .connect(this.accounts.deployer)
      .addProject("name", this.accounts.artist.address);
    await this.genArt721Core
      .connect(this.accounts.deployer)
      .toggleProjectIsActive(this.projectZero);
    await this.genArt721Core
      .connect(this.accounts.artist)
      .updateProjectMaxInvocations(this.projectZero, this.maxInvocations);

    // add project one without setting it to active or setting max invocations
    await this.genArt721Core
      .connect(this.accounts.deployer)
      .addProject("name", this.accounts.artist2.address);

    // configure minter for project zero
    await this.minterFilter
      .connect(this.accounts.deployer)
      .addApprovedMinter(this.minter.address);
    await this.minterFilter
      .connect(this.accounts.deployer)
      .setMinterForProject(this.projectZero, this.minter.address);
    await this.minter
      .connect(this.accounts.artist)
      .updatePricePerTokenInWei(this.projectZero, 0);
  });

  describe("imported scripts are non-empty", function () {
    it("ensure diffs are captured if project scripts are deleted", async function () {
      expect(SQUIGGLE_SCRIPT.length).to.be.gt(0);
      expect(SKULPTUUR_SCRIPT_APPROX.length).to.be.gt(0);
      expect(CONTRACT_SIZE_LIMIT_SCRIPT.length).to.be.gt(0);
      expect(RANDOM_UTF_EIGHT_SCRIPT.length).to.be.gt(0);
    });
  });

  describe("updateProjectMaxInvocations", function () {
    it("only allows artist to update", async function () {
      // deployer cannot update
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.deployer)
          .updateProjectMaxInvocations(
            this.projectZero,
            this.maxInvocations - 1
          ),
        "Only artist"
      );
      // artist can update
      await this.genArt721Core
        .connect(this.accounts.artist)
        .updateProjectMaxInvocations(this.projectZero, this.maxInvocations - 1);
    });

    it("only allows maxInvocations to be reduced", async function () {
      // invocations must be reduced
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.artist)
          .updateProjectMaxInvocations(this.projectZero, this.maxInvocations),
        "maxInvocations may only be decreased"
      );
      // artist can reduce
      await this.genArt721Core
        .connect(this.accounts.artist)
        .updateProjectMaxInvocations(this.projectZero, this.maxInvocations - 1);
    });

    it("only allows maxInvocations to be gte current invocations", async function () {
      // mint a token on project zero
      await this.minter
        .connect(this.accounts.artist)
        .purchase(this.projectZero);
      // invocations cannot be < current invocations
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.artist)
          .updateProjectMaxInvocations(this.projectZero, 0),
        "Only max invocations gte current invocations"
      );
      // artist can set to greater than current invocations
      await this.genArt721Core
        .connect(this.accounts.artist)
        .updateProjectMaxInvocations(this.projectZero, 2);
      // artist can set to equal to current invocations
      await this.genArt721Core
        .connect(this.accounts.artist)
        .updateProjectMaxInvocations(this.projectZero, 1);
    });
  });

  describe("project complete state", function () {
    it("project may not mint when is completed due to reducing maxInvocations", async function () {
      // mint a token on project zero
      await this.minter
        .connect(this.accounts.artist)
        .purchase(this.projectZero);
      // set max invocations to number of invocations
      await this.genArt721Core
        .connect(this.accounts.artist)
        .updateProjectMaxInvocations(this.projectZero, 1);
      // expect project to not mint when completed
      expectRevert(
        this.minter.connect(this.accounts.artist).purchase(this.projectZero),
        "Must not exceed max invocations"
      );
      // confirm project is completed via view function
      const projectStateData = await this.genArt721Core.projectStateData(
        this.projectZero
      );
      expect(projectStateData.completedTimestamp).to.be.gt(0);
    });

    it("project may not mint when is completed due to minting out", async function () {
      // project mints out
      for (let i = 0; i < this.maxInvocations; i++) {
        await this.minter
          .connect(this.accounts.artist)
          .purchase(this.projectZero);
      }
      // expect project to not mint when completed
      expectRevert(
        this.minter.connect(this.accounts.artist).purchase(this.projectZero),
        "Must not exceed max invocations"
      );
      // confirm project is completed via view function
      const projectStateData = await this.genArt721Core.projectStateData(
        this.projectZero
      );
      expect(projectStateData.completedTimestamp).to.be.gt(0);
    });
  });

  describe("projectLocked", function () {
    it("project is not locked by default", async function () {
      const projectStateData = await this.genArt721Core
        .connect(this.accounts.user)
        .projectStateData(this.projectZero);
      expect(projectStateData.locked).to.equal(false);
    });

    it("project is not locked < 4 weeks after being completed", async function () {
      // project is completed
      for (let i = 0; i < this.maxInvocations; i++) {
        await this.minter
          .connect(this.accounts.artist)
          .purchase(this.projectZero);
      }
      let projectStateData = await this.genArt721Core
        .connect(this.accounts.user)
        .projectStateData(this.projectZero);
      expect(projectStateData.locked).to.equal(false);
      // advance < 4 weeks
      await advanceEVMByTime(FOUR_WEEKS - 1);
      projectStateData = await this.genArt721Core
        .connect(this.accounts.user)
        .projectStateData(this.projectZero);
      // expect project to not be locked
      expect(projectStateData.locked).to.equal(false);
    });

    it("project is locked > 4 weeks after being minted out", async function () {
      // project is completed
      for (let i = 0; i < this.maxInvocations; i++) {
        await this.minter
          .connect(this.accounts.artist)
          .purchase(this.projectZero);
      }
      // advance > 4 weeks
      await advanceEVMByTime(FOUR_WEEKS + 1);
      const projectStateData = await this.genArt721Core
        .connect(this.accounts.user)
        .projectStateData(this.projectZero);
      // expect project to be locked
      expect(projectStateData.locked).to.equal(true);
    });
  });

  describe("updateProjectDescription", function () {
    const errorMessage = "Only artist when unlocked, owner when locked";
    it("owner cannot update when unlocked", async function () {
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.deployer)
          .updateProjectDescription(this.projectZero, "new description"),
        errorMessage
      );
    });

    it("artist can update when unlocked", async function () {
      await this.genArt721Core
        .connect(this.accounts.artist)
        .updateProjectDescription(this.projectZero, "new description");
      // expect view to be updated
      const projectDetails = await this.genArt721Core
        .connect(this.accounts.user)
        .projectDetails(this.projectZero);
      expect(projectDetails.description).to.equal("new description");
    });

    it("owner can update when locked", async function () {
      await mintProjectUntilRemaining.call(
        this,
        this.projectZero,
        this.accounts.artist,
        0
      );
      await advanceEVMByTime(FOUR_WEEKS + 1);
      await this.genArt721Core
        .connect(this.accounts.deployer)
        .updateProjectDescription(this.projectZero, "new description");
      // expect view to be updated
      const projectDetails = await this.genArt721Core
        .connect(this.accounts.user)
        .projectDetails(this.projectZero);
      expect(projectDetails.description).to.equal("new description");
    });

    it("artist cannot update when locked", async function () {
      await mintProjectUntilRemaining.call(
        this,
        this.projectZero,
        this.accounts.artist,
        0
      );
      await advanceEVMByTime(FOUR_WEEKS + 1);
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.artist)
          .updateProjectDescription(this.projectZero, "new description"),
        errorMessage
      );
    });
  });

  describe("updateProjectName", function () {
    const errorMessage = "Only artist when unlocked, owner when locked";
    it("owner can update when unlocked", async function () {
      await this.genArt721Core
        .connect(this.accounts.deployer)
        .updateProjectName(this.projectZero, "new name");
    });

    it("artist can update when unlocked", async function () {
      await this.genArt721Core
        .connect(this.accounts.artist)
        .updateProjectName(this.projectZero, "new name");
      // expect view to be updated
      const projectDetails = await this.genArt721Core
        .connect(this.accounts.user)
        .projectDetails(this.projectZero);
      expect(projectDetails.projectName).to.equal("new name");
    });

    it("owner can not update when locked", async function () {
      await mintProjectUntilRemaining.call(
        this,
        this.projectZero,
        this.accounts.artist,
        0
      );
      await advanceEVMByTime(FOUR_WEEKS + 1);
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.deployer)
          .updateProjectName(this.projectZero, "new description"),
        "Only if unlocked"
      );
    });

    it("user cannot update", async function () {
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.user)
          .updateProjectName(this.projectZero, "new description"),
        "Only artist or Admin ACL allowed"
      );
    });
  });

  describe("updateProjectScriptType", function () {
    const errorMessage = "Only artist when unlocked, owner when locked";
    it("owner can update when unlocked", async function () {
      await this.genArt721Core
        .connect(this.accounts.deployer)
        .updateProjectScriptType(
          this.projectZero,
          ethers.utils.formatBytes32String("p5js@v1.2.3")
        );
    });

    it("artist can update when unlocked", async function () {
      await this.genArt721Core
        .connect(this.accounts.artist)
        .updateProjectScriptType(
          this.projectZero,
          ethers.utils.formatBytes32String("p5js@v1.2.3")
        );
    });

    it("view is updated when value is updated", async function () {
      await this.genArt721Core
        .connect(this.accounts.artist)
        .updateProjectScriptType(
          this.projectZero,
          ethers.utils.formatBytes32String("p5js@v1.2.3")
        );
      // expect view to be updated
      const projectDetails = await this.genArt721Core
        .connect(this.accounts.user)
        .projectScriptDetails(this.projectZero);
      expect(projectDetails.scriptTypeAndVersion).to.equal("p5js@v1.2.3");
    });

    it("value must contain exactly one `@`", async function () {
      // test too few @
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.artist)
          .updateProjectScriptType(
            this.projectZero,
            ethers.utils.formatBytes32String("p5js_v1.2.3")
          ),
        "must contain exactly one @"
      );
      // test too many @
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.artist)
          .updateProjectScriptType(
            this.projectZero,
            ethers.utils.formatBytes32String("p5@js@v1.2.3")
          ),
        "must contain exactly one @"
      );
    });

    it("owner can not update when locked", async function () {
      await mintProjectUntilRemaining.call(
        this,
        this.projectZero,
        this.accounts.artist,
        0
      );
      await advanceEVMByTime(FOUR_WEEKS + 1);
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.deployer)
          .updateProjectScriptType(
            this.projectZero,
            ethers.utils.formatBytes32String("p5js@v1.2.3")
          ),
        "Only if unlocked"
      );
    });

    it("user cannot update", async function () {
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.user)
          .updateProjectScriptType(
            this.projectZero,
            ethers.utils.formatBytes32String("p5js@v1.2.3")
          ),
        "Only artist or Admin ACL allowed"
      );
    });
  });

  describe("updateProjectArtistAddress", function () {
    it("only allows owner to update project artist address", async function () {
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.artist)
          .updateProjectArtistAddress(
            this.projectZero,
            this.accounts.artist2.address
          ),
        "Only Admin ACL allowed"
      );
      this.genArt721Core
        .connect(this.accounts.deployer)
        .updateProjectArtistAddress(
          this.projectZero,
          this.accounts.artist2.address
        );
    });

    it("reflects updated artist address", async function () {
      this.genArt721Core
        .connect(this.accounts.deployer)
        .updateProjectArtistAddress(
          this.projectZero,
          this.accounts.artist2.address
        );
      // expect view to reflect update
      const projectArtistPaymentInfo = await this.genArt721Core
        .connect(this.accounts.deployer)
        .projectArtistPaymentInfo(this.projectZero);
      expect(projectArtistPaymentInfo.artistAddress).to.equal(
        this.accounts.artist2.address
      );
    });
  });

  describe("update project payment addresses", function () {
    beforeEach(async function () {
      this.valuesToUpdateTo = [
        this.projectZero,
        this.accounts.artist2.address,
        this.accounts.additional.address,
        50,
        this.accounts.additional2.address,
        51,
      ];
    });

    it("only allows artist to propose updates", async function () {
      // rejects deployer as a proposer of updates
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.deployer)
          .proposeArtistPaymentAddressesAndSplits(...this.valuesToUpdateTo),
        "Only artist"
      );
      // rejects user as a proposer of updates
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.user)
          .proposeArtistPaymentAddressesAndSplits(...this.valuesToUpdateTo),
        "Only artist"
      );
      // allows artist to propose new values
      await this.genArt721Core
        .connect(this.accounts.artist)
        .proposeArtistPaymentAddressesAndSplits(...this.valuesToUpdateTo);
    });

    it("does not allow artist to propose invalid", async function () {
      // rejects artist proposal primary >100% to additional
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.artist)
          .proposeArtistPaymentAddressesAndSplits(
            this.projectZero,
            this.accounts.artist2.address,
            this.accounts.additional.address,
            101,
            this.accounts.additional2.address,
            0
          ),
        "Max of 100%"
      );
      // rejects artist proposal secondary >100% to additional
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.artist)
          .proposeArtistPaymentAddressesAndSplits(
            this.projectZero,
            this.accounts.artist2.address,
            this.accounts.additional.address,
            0,
            this.accounts.additional2.address,
            101
          ),
        "Max of 100%"
      );
    });

    it("only allows adminACL-allowed account to accept updates if owner has not renounced ownership", async function () {
      // artist proposes new values
      await this.genArt721Core
        .connect(this.accounts.artist)
        .proposeArtistPaymentAddressesAndSplits(...this.valuesToUpdateTo);
      // rejects artist as an acceptor of updates
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.artist)
          .adminAcceptArtistAddressesAndSplits(...this.valuesToUpdateTo),
        "Only Admin ACL allowed"
      );
      // rejects user as an acceptor of updates
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.user)
          .adminAcceptArtistAddressesAndSplits(...this.valuesToUpdateTo),
        "Only Admin ACL allowed"
      );
      // allows deployer to accept new values
      await this.genArt721Core
        .connect(this.accounts.deployer)
        .adminAcceptArtistAddressesAndSplits(...this.valuesToUpdateTo);
    });

    it("only allows artist account to accept proposed updates if owner has renounced ownership", async function () {
      // artist proposes new values
      await this.genArt721Core
        .connect(this.accounts.artist)
        .proposeArtistPaymentAddressesAndSplits(...this.valuesToUpdateTo);
      // admin renounces ownership
      await this.adminACL
        .connect(this.accounts.deployer)
        .renounceOwnershipOn(this.genArt721Core.address);
      // deployer may no longer accept proposed values
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.deployer)
          .adminAcceptArtistAddressesAndSplits(...this.valuesToUpdateTo),
        "Only Admin ACL allowed, or artist if owner has renounced"
      );
      // user may not accept proposed values
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.user)
          .adminAcceptArtistAddressesAndSplits(...this.valuesToUpdateTo),
        "Only Admin ACL allowed, or artist if owner has renounced"
      );
      // artist may accept proposed values
      await this.genArt721Core
        .connect(this.accounts.artist)
        .adminAcceptArtistAddressesAndSplits(...this.valuesToUpdateTo);
    });

    it("does not allow adminACL-allowed account to accept updates that don't match artist proposed values", async function () {
      // artist proposes new values
      await this.genArt721Core
        .connect(this.accounts.artist)
        .proposeArtistPaymentAddressesAndSplits(...this.valuesToUpdateTo);
      // rejects deployer's updates if they don't match artist's proposed values
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.deployer)
          .adminAcceptArtistAddressesAndSplits(
            this.valuesToUpdateTo[0],
            this.valuesToUpdateTo[1],
            this.valuesToUpdateTo[2],
            this.valuesToUpdateTo[3],
            this.valuesToUpdateTo[4],
            this.valuesToUpdateTo[5] + 1
          ),
        "Must match artist proposal"
      );
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.deployer)
          .adminAcceptArtistAddressesAndSplits(
            this.valuesToUpdateTo[0],
            this.valuesToUpdateTo[1],
            this.valuesToUpdateTo[2],
            this.valuesToUpdateTo[3],
            this.valuesToUpdateTo[2],
            this.valuesToUpdateTo[5]
          ),
        "Must match artist proposal"
      );
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.deployer)
          .adminAcceptArtistAddressesAndSplits(
            this.valuesToUpdateTo[0],
            this.valuesToUpdateTo[1],
            this.valuesToUpdateTo[2],
            this.valuesToUpdateTo[3] - 1,
            this.valuesToUpdateTo[4],
            this.valuesToUpdateTo[5]
          ),
        "Must match artist proposal"
      );
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.deployer)
          .adminAcceptArtistAddressesAndSplits(
            this.valuesToUpdateTo[0],
            this.valuesToUpdateTo[1],
            this.valuesToUpdateTo[4],
            this.valuesToUpdateTo[3],
            this.valuesToUpdateTo[4],
            this.valuesToUpdateTo[5]
          ),
        "Must match artist proposal"
      );
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.deployer)
          .adminAcceptArtistAddressesAndSplits(
            this.valuesToUpdateTo[0],
            this.accounts.user.address,
            this.valuesToUpdateTo[2],
            this.valuesToUpdateTo[3],
            this.valuesToUpdateTo[4],
            this.valuesToUpdateTo[5]
          ),
        "Must match artist proposal"
      );
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.deployer)
          .adminAcceptArtistAddressesAndSplits(
            this.projectOne,
            this.valuesToUpdateTo[1],
            this.valuesToUpdateTo[2],
            this.valuesToUpdateTo[3],
            this.valuesToUpdateTo[4],
            this.valuesToUpdateTo[5]
          ),
        "Must match artist proposal"
      );
    });

    it("only allows adminACL-allowed account to accept updates once (i.e. proposal is cleared upon acceptance)", async function () {
      // artist proposes new values
      await this.genArt721Core
        .connect(this.accounts.artist)
        .proposeArtistPaymentAddressesAndSplits(...this.valuesToUpdateTo);
      // allows deployer to accept new values
      await this.genArt721Core
        .connect(this.accounts.deployer)
        .adminAcceptArtistAddressesAndSplits(...this.valuesToUpdateTo);
      // reverts if deployer tries to accept again
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.deployer)
          .adminAcceptArtistAddressesAndSplits(...this.valuesToUpdateTo),
        "Must match artist proposal"
      );
    });
  });

  describe("updateProjectSecondaryMarketRoyaltyPercentage", function () {
    it("owner can not update when unlocked", async function () {
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.deployer)
          .updateProjectSecondaryMarketRoyaltyPercentage(this.projectZero, 10),
        "Only artist"
      );
    });

    it("artist can update when unlocked", async function () {
      await this.genArt721Core
        .connect(this.accounts.artist)
        .updateProjectSecondaryMarketRoyaltyPercentage(this.projectZero, 10);
      // expect view to be updated
      const royaltyData = await this.genArt721Core
        .connect(this.accounts.user)
        .getRoyaltyData(this.projectZero);
      expect(royaltyData.royaltyFeeByID).to.equal(10);
    });

    it("artist can update when locked", async function () {
      await mintProjectUntilRemaining.call(
        this,
        this.projectZero,
        this.accounts.artist,
        0
      );
      await advanceEVMByTime(FOUR_WEEKS + 1);
      await this.genArt721Core
        .connect(this.accounts.artist)
        .updateProjectSecondaryMarketRoyaltyPercentage(this.projectZero, 11);
      // expect view to be updated
      const royaltyData = await this.genArt721Core
        .connect(this.accounts.user)
        .getRoyaltyData(this.projectZero);
      expect(royaltyData.royaltyFeeByID).to.equal(11);
    });

    it("artist cannot update > 95%", async function () {
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.artist)
          .updateProjectSecondaryMarketRoyaltyPercentage(this.projectZero, 96),
        "Max of 95%"
      );
    });
  });

  describe("addProjectScript", function () {
    it("uploads and recalls an empty script", async function () {
      await this.genArt721Core
        .connect(this.accounts.artist)
        .addProjectScript(this.projectZero, "");
      const script = await this.genArt721Core.projectScriptByIndex(
        this.projectZero,
        0
      );
      expect(script).to.equal("");
    });

    it("uploads and recalls an short script < 32 bytes", async function () {
      const targetScript = "console.log(hello world)";
      await this.genArt721Core
        .connect(this.accounts.artist)
        .addProjectScript(this.projectZero, targetScript);
      const script = await this.genArt721Core.projectScriptByIndex(
        this.projectZero,
        0
      );
      expect(script).to.equal(targetScript);
    });

    it("uploads and recalls chromie squiggle script", async function () {
      await this.genArt721Core
        .connect(this.accounts.artist)
        .addProjectScript(this.projectZero, SQUIGGLE_SCRIPT);
      const script = await this.genArt721Core.projectScriptByIndex(
        this.projectZero,
        0
      );
      expect(script).to.equal(SQUIGGLE_SCRIPT);
    });

    it("uploads chromie squiggle script, and then purges it", async function () {
      await this.genArt721Core
        .connect(this.accounts.artist)
        .addProjectScript(this.projectZero, SQUIGGLE_SCRIPT);
      const script = await this.genArt721Core.projectScriptByIndex(
        this.projectZero,
        0
      );
      expect(script).to.equal(SQUIGGLE_SCRIPT);

      const scriptAddress =
        await this.genArt721Core.projectScriptBytecodeAddressByIndex(
          this.projectZero,
          0
        );

      const scriptByteCode = await ethers.provider.getCode(scriptAddress);
      expect(scriptByteCode).to.not.equal("0x");

      await this.genArt721Core
        .connect(this.accounts.artist)
        .removeProjectLastScript(this.projectZero);
      const emptyScript = await this.genArt721Core.projectScriptByIndex(
        this.projectZero,
        0
      );
      expect(emptyScript).to.equal("");

      const removedScriptByteCode = await ethers.provider.getCode(
        scriptAddress
      );
      expect(removedScriptByteCode).to.equal("0x");
    });

    it("uploads chromie squiggle script and attempts to purge from non-allowed address", async function () {
      await this.genArt721Core
        .connect(this.accounts.artist)
        .addProjectScript(this.projectZero, SQUIGGLE_SCRIPT);
      const script = await this.genArt721Core.projectScriptByIndex(
        this.projectZero,
        0
      );
      expect(script).to.equal(SQUIGGLE_SCRIPT);

      const scriptAddress =
        await this.genArt721Core.projectScriptBytecodeAddressByIndex(
          this.projectZero,
          0
        );

      const scriptByteCode = await ethers.provider.getCode(scriptAddress);
      expect(scriptByteCode).to.not.equal("0x");

      // Any random user should **not** be able to purge bytecode storage.
      await expectRevert.unspecified(
        this.accounts.user.call({
          to: scriptAddress,
        })
      );
      // Nor should even the core contract deployer be able to do so directly.
      await expectRevert.unspecified(
        this.accounts.deployer.call({
          to: scriptAddress,
        })
      );

      const sameScriptByteCode = await ethers.provider.getCode(scriptAddress);
      expect(sameScriptByteCode).to.equal(scriptByteCode);
      expect(sameScriptByteCode).to.not.equal("0x");
    });

    it("uploads and recalls different script", async function () {
      await this.genArt721Core
        .connect(this.accounts.artist)
        .addProjectScript(this.projectZero, SKULPTUUR_SCRIPT_APPROX);
      const script = await this.genArt721Core.projectScriptByIndex(
        this.projectZero,
        0
      );
      expect(script).to.equal(SKULPTUUR_SCRIPT_APPROX);
    });

    it("uploads and recalls 23.95 KB script", async function () {
      await this.genArt721Core
        .connect(this.accounts.artist)
        .addProjectScript(this.projectZero, CONTRACT_SIZE_LIMIT_SCRIPT, {
          gasLimit: 30000000, // hard-code gas limit because ethers sometimes estimates too high
        });
      const script = await this.genArt721Core.projectScriptByIndex(
        this.projectZero,
        0
      );
      expect(script).to.equal(CONTRACT_SIZE_LIMIT_SCRIPT);
    });

    it("uploads and recalls misc. UTF-8 script", async function () {
      await this.genArt721Core
        .connect(this.accounts.artist)
        .addProjectScript(this.projectZero, RANDOM_UTF_EIGHT_SCRIPT);
      const script = await this.genArt721Core.projectScriptByIndex(
        this.projectZero,
        0
      );
      expect(script).to.equal(RANDOM_UTF_EIGHT_SCRIPT);
    });

    it("uploads and recalls chromie squiggle script and different script", async function () {
      // index 0: squiggle
      await this.genArt721Core
        .connect(this.accounts.artist)
        .addProjectScript(this.projectZero, SQUIGGLE_SCRIPT);
      // index 1: skulptuur-like
      await this.genArt721Core
        .connect(this.accounts.artist)
        .addProjectScript(this.projectZero, SKULPTUUR_SCRIPT_APPROX);
      // verify results
      const scriptZero = await this.genArt721Core.projectScriptByIndex(
        this.projectZero,
        0
      );
      expect(scriptZero).to.equal(SQUIGGLE_SCRIPT);
      const scriptOne = await this.genArt721Core.projectScriptByIndex(
        this.projectZero,
        1
      );
      expect(scriptOne).to.equal(SKULPTUUR_SCRIPT_APPROX);
    });
  });

  describe("projectScriptBytecodeAddressByIndex", function () {
    it("uploads and recalls an empty script", async function () {
      await this.genArt721Core
        .connect(this.accounts.artist)
        .addProjectScript(this.projectZero, "");
      const scriptBytecodeAddress =
        await this.genArt721Core.projectScriptBytecodeAddressByIndex(
          this.projectZero,
          0
        );
      console.log(scriptBytecodeAddress);
      expect(scriptBytecodeAddress).to.not.equal("");
    });
  });

  describe("updateProjectScript", function () {
    beforeEach(async function () {
      await this.genArt721Core
        .connect(this.accounts.artist)
        .addProjectScript(this.projectZero, "// script 0");
    });

    it("owner can update when unlocked", async function () {
      await this.genArt721Core
        .connect(this.accounts.deployer)
        .updateProjectScript(this.projectZero, 0, "// script 0.1");
    });

    it("artist can update when unlocked", async function () {
      await this.genArt721Core
        .connect(this.accounts.artist)
        .updateProjectScript(this.projectZero, 0, "// script 0.1");
    });

    it("artist cannot update when locked", async function () {
      await mintProjectUntilRemaining.call(
        this,
        this.projectZero,
        this.accounts.artist,
        0
      );
      await advanceEVMByTime(FOUR_WEEKS + 1);
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.artist)
          .updateProjectScript(this.projectZero, 0, "// script 0.1"),
        "Only if unlocked"
      );
    });

    it("artist cannot update non-existing script index", async function () {
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.artist)
          .updateProjectScript(this.projectZero, 1, "// script 1"),
        "scriptId out of range"
      );
    });

    it("bytecode contracts deployed and purged as expected in updates", async function () {
      const originalScriptAddress =
        await this.genArt721Core.projectScriptBytecodeAddressByIndex(
          this.projectZero,
          0
        );

      const scriptByteCode = await ethers.provider.getCode(
        originalScriptAddress
      );
      expect(scriptByteCode).to.not.equal("0x");

      await this.genArt721Core
        .connect(this.accounts.artist)
        .updateProjectScript(this.projectZero, 0, "// script 0.1");

      const oldAddressByteCode = await ethers.provider.getCode(
        originalScriptAddress
      );
      expect(oldAddressByteCode).to.equal("0x");

      const newScriptAddress =
        await this.genArt721Core.projectScriptBytecodeAddressByIndex(
          this.projectZero,
          0
        );
      const newScriptByteCode = await ethers.provider.getCode(newScriptAddress);
      expect(newScriptByteCode).to.not.equal("0x");
      expect(newScriptByteCode).to.not.equal(scriptByteCode);
      expect(newScriptByteCode).to.not.equal(oldAddressByteCode);
    });
  });

  describe("removeProjectLastScript", function () {
    beforeEach(async function () {
      await this.genArt721Core
        .connect(this.accounts.artist)
        .addProjectScript(this.projectZero, "// script 0");
    });

    it("owner can remove when unlocked", async function () {
      await this.genArt721Core
        .connect(this.accounts.deployer)
        .removeProjectLastScript(this.projectZero);
    });

    it("artist can remove when unlocked", async function () {
      await this.genArt721Core
        .connect(this.accounts.artist)
        .removeProjectLastScript(this.projectZero);
    });

    it("artist cannot remove when locked", async function () {
      await mintProjectUntilRemaining.call(
        this,
        this.projectZero,
        this.accounts.artist,
        0
      );
      await advanceEVMByTime(FOUR_WEEKS + 1);
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.artist)
          .removeProjectLastScript(this.projectZero),
        "Only if unlocked"
      );
    });

    it("artist cannot update non-existing script index", async function () {
      // remove existing script
      await this.genArt721Core
        .connect(this.accounts.artist)
        .removeProjectLastScript(this.projectZero);
      // expect revert when tyring to remove again
      await expectRevert(
        this.genArt721Core
          .connect(this.accounts.artist)
          .removeProjectLastScript(this.projectZero),
        "there are no scripts to remove"
      );
    });
  });
});
