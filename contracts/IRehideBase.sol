// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

interface IRehideBase {
    event SetPlatformWallet(address platformWallet);
    event SetMinEthMintPrice(uint256 minEthMintPrice);
    event SetPrimaryReferrerPercentage(uint256 primaryReferrerPercentage);
    event SetSecondaryReferrerPercentage(uint256 secondaryReferrerPercentage);
    event SetMaxReferrerLevels(uint256 maxReferrerLevels);
    event SetMaxReferrerRewardsPercentage(uint256 maxReferrerRewardsPercentage);
    event SetReadPlatformPercentage(uint256 readPlatformPercentage);
    event RemoveFromReferrerTierList(address[] toRemoveAddresses);
}
