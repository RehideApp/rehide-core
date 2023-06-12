// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./IRehideNFT.sol";
import "./RehideBase.sol";

// https://docs.openzeppelin.com/contracts/4.x/api/token/erc721

contract RehideNFT is IRehideNFT, RehideBase {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    bool public _isPaused;

    /**
     * @dev NFT
     */
    using Counters for Counters.Counter;
    Counters.Counter private _tokenIds;
    string private baseURI = "ipfs://";

    /**
     * @dev Reads
     */
    mapping(uint256 => Note) public _notesMapping;
    Counters.Counter public _noteCount;
    mapping(address => uint256[]) internal _tokenIdsForAddress;
    mapping(uint256 => NoteRead[]) public _noteReads;
    mapping(address => uint256[]) public _addressReadNotes;
    mapping(uint256 => address[]) public _noteReadAllowlistAddresses;
    mapping(uint256 => address[]) public _noteReadDenylistAddresses;

    /**
     * @dev Mint Pass
     */
    mapping(uint256 => uint256) public _passTtlMapping;

    /**
     * @dev Notes Shared with Address
     */
    mapping(address => uint256[]) public _notesSharedWithAddress;
    mapping(address => uint256[]) public _notesDeniedForAddress;

    /**
     * @dev Addresses on deny list by Address / Platform
     */
    mapping(address => address[]) public _addressBlacklistForAddress; // user's blacklist
    mapping(address => uint256) public _addressBlacklistReportsCount; // count how many times address is reported
    address[] public _addressBlacklistForPlatform; // platform's blacklist

    /**
     * @dev Referrer Tiers
     */
    Counters.Counter public _tierCount;
    mapping(uint256 => uint256) public _tierRebate; 

    constructor(string memory name_,string memory symbol_) ERC721(name_, symbol_) {}

    function pause() external onlyOwner {
        _pause();
        _isPaused = true;
        emit Pause(block.timestamp);
    }

    function unpause() external onlyOwner {
        _unpause();
        _isPaused = false;
        emit Unpause(block.timestamp);
    }

    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }

    function setBaseURI(string memory uri) external onlyOwner {
        baseURI = uri;
        emit SetBaseURI(baseURI);
    }

    /**
     * @dev Set referral tier
     */
    function setTier(uint256 tierId, uint256 rebate) external onlyOwner {
        require(tierId > 0, "RehideNFT: Invalid tierId");
        require(rebate <= _maxReferrerRewardsPercentage, "RehideNFT: Referrer rebate exceed max allowed.");

        // If new tier (could be updating existing)
        if (_tierRebate[tierId] == 0) {
            _tierCount.increment();
        }

        _tierRebate[tierId] = rebate;
        emit SetTier(tierId, rebate);
    }

    /**
     * @dev Link referrer and tier
     */
    function addToReferrerTierList(address[] calldata toAddAddresses, uint256 tierId) external onlyOwner {
        require(toAddAddresses.length > 0, "RehideNFT: No addresses to add");
        require(tierId >= 0, "RehideNFT: Invalid tierId");
        require(_tierRebate[tierId] > 0, "RehideNFT: Invalid tier");

        for (uint256 i = 0; i < toAddAddresses.length; i++) {
            if (_referrerTierList[toAddAddresses[i]] == 0) {
                _referrerTierCount.increment();
            }
            _referrerTierList[toAddAddresses[i]] = tierId;
        }
        emit AddToReferrerTierList(toAddAddresses, tierId);
    }

    /**
     * @dev Remove link between referrer and tier
     */
    function removeFromReferrerTierList(address[] calldata toRemoveAddresses) external onlyOwner {
        for (uint256 i = 0; i < toRemoveAddresses.length; i++) {
            if (_referrerTierList[toRemoveAddresses[i]] > 0) {
                _referrerTierList[toRemoveAddresses[i]] = 0;
                _referrerTierCount.decrement();
            }
        }
        emit RemoveFromReferrerTierList(toRemoveAddresses);
    }

    /**
     * @dev If ETH is transferred directly to contract
     */
    function withdraw() external onlyOwner returns (uint256) {
        uint256 balance = address(this).balance;
        if(balance > 0){
            Address.sendValue(payable(owner()), balance);
        }
        emit Withdraw(balance);
        return balance;
    }

    function mintPass(
        address recipient, 
        string memory uri, 
        address payable referrer,
        uint256 ttl) 
        public payable whenNotPaused returns (uint256) {

        if (recipient == address(0)) {
            recipient = _msgSender();
        }

        uint256 newTokenId = doMintNFT(recipient, uri);
        emit MintNFT(newTokenId, uri, recipient, msg.value);

        require(newTokenId > 0, "RehideNFT: Error minting NFT");

        _tokenIdsForAddress[_msgSender()].push(newTokenId);

        if (ttl > 0) {
            ttl += block.timestamp;
        }
        _passTtlMapping[newTokenId] = ttl;
        
        // Referrer Rewards Distribution
        distributeReferrerRewards(referrer);

        return newTokenId;
    }

    function mintNFT(
        address recipient, 
        string memory uri, 
        address payable referrer,
        Note memory note,
        address[] memory allowlistAddresses) 
        public payable whenNotPaused returns (uint256) {

        if (recipient == address(0)) {
            recipient = _msgSender();
        }

        uint256 newTokenId = doMintNFT(recipient, uri);
        emit MintNFT(newTokenId, uri, recipient, msg.value);

        require(newTokenId > 0, "RehideNFT: Error minting NFT");

        note.creator = _msgSender();
        note.ttl += block.timestamp;

        _tokenIdsForAddress[_msgSender()].push(newTokenId);
        _notesMapping[newTokenId] = note;
        _noteCount.increment();

        if (allowlistAddresses.length > 0) {
            addToReadAllowlist(newTokenId, allowlistAddresses);
        }
        
        // Referrer Rewards Distribution
        distributeReferrerRewards(referrer);

        return newTokenId;
    }

    function readSharedNote(uint256 tokenId, uint256 platformFee) public payable returns (uint256 readsAvailable) {
        require(_exists(tokenId), "RehideNFT: Token not found");

        Note storage note = _notesMapping[tokenId];

        uint256 readFee = msg.value;
        if (_msgSender() != owner() && ownerOf(tokenId) != _msgSender()) {
            require(readFee >= note.readPrice, "RehideNFT: Not enough ETH sent");
        }

        if (note.allowlistOnly > 0) {
            bool isAllowed = false;
            address[] memory noteReadAllowlistAddresses = _noteReadAllowlistAddresses[tokenId];
            for (uint256 i = 0; i < noteReadAllowlistAddresses.length; i++) {
                if (_msgSender() == noteReadAllowlistAddresses[i]) {
                    isAllowed = true;
                    break;
                }
            }
            require(isAllowed, "RehideNFT: Not on allowlist");
        }

        // Check denylist
        address[] memory noteReadDenylistAddresses = _noteReadDenylistAddresses[tokenId];
        if (noteReadDenylistAddresses.length > 0) {
            bool isDenied = false;
            for (uint256 i = 0; i < noteReadDenylistAddresses.length; i++) {
                if (_msgSender() == noteReadDenylistAddresses[i]) {
                    isDenied = true;
                    break;
                }
            }
            require(isDenied, "RehideNFT: Address is in denylist");
        }

        NoteRead memory noteRead = NoteRead({
            reader: _msgSender(),
            timestamp: block.timestamp
        });
        
        _noteReads[tokenId].push(noteRead);
        _addressReadNotes[_msgSender()].push(tokenId);
        emit ReadSharedNote(tokenId, _msgSender(), block.timestamp);

        require(note.readsAvailable > 0, "RehideNFT: Data for token not found (max. reads exceeded)");
        require(note.ttl > block.timestamp, "RehideNFT: Data for token not found (expired)");
        
        note.readsAvailable -= 1;
        if (note.readsAvailable < 1){
            setExpireNote(tokenId);
            // delete _notesMapping[tokenId];
        }

        readsAvailable = note.readsAvailable;

        if (readFee > 0) {

            if (platformFee > 0) {
                _totalPlatformReadFees += platformFee;
                (bool platformTransferSuccess, ) = _platformWallet.call{value: platformFee}("");
                require(platformTransferSuccess, "RehideNFT: Failed to transfer platform fee");
                emit ReadSharedNoteRewardsTransferred(_platformWallet, tokenId, platformFee);
            }

            address payable payableCreator = payable(note.creator);
            uint256 creatorFee = readFee - platformFee;
            _creatorReadFees[payableCreator] += creatorFee;
            _totalCreatorsReadFees += creatorFee;
            (bool creatorTransferSuccess, ) = payableCreator.call{value: creatorFee}("");
            require(creatorTransferSuccess, "RehideNFT: Failed to transfer creator fee");
            emit ReadSharedNoteRewardsTransferred(payableCreator, tokenId, creatorFee);
        }
    }

    /**
     * @dev To limit what addresses can read the note
     */
    function addToReadAllowlist(uint256 tokenId, address[] memory toAddAddresses) public {
        require(_exists(tokenId), "RehideNFT: Allowlist set of nonexistent token");
        require(ownerOf(tokenId) == _msgSender(), "RehideNFT: Trying to set another wallet's token allowlist");
        require(toAddAddresses.length > 0, "RehideNFT: No addresses to add");

        for (uint256 i = 0; i < toAddAddresses.length; i++) {
            _noteReadAllowlistAddresses[tokenId].push(toAddAddresses[i]); // tokenId => address
            if (toAddAddresses[i] != _msgSender()) { // only add if not self
                _notesSharedWithAddress[toAddAddresses[i]].push(tokenId); // address => tokenId
            }
        }

        updateAllowListOnly(tokenId, _noteReadAllowlistAddresses[tokenId].length);
        emit AddToReadAllowlist(tokenId, toAddAddresses);
    }

    /**
     * @dev To avoid deleting from allowlist - this denylist overrides the permission to read 
     * If a wallet is on (Allowlist and) Denylist, they can't read it
     */
    function addToReadDenylist(uint256 tokenId, address[] memory toAddAddresses) public {
        require(_exists(tokenId), "RehideNFT: Denylist set of nonexistent token");
        require(ownerOf(tokenId) == _msgSender(), "RehideNFT: Trying to set another wallet's token denylist");
        require(toAddAddresses.length > 0, "RehideNFT: No addresses to add");

        for (uint256 i = 0; i < toAddAddresses.length; i++) {
            _noteReadDenylistAddresses[tokenId].push(toAddAddresses[i]); // tokenId => address
            _notesDeniedForAddress[toAddAddresses[i]].push(tokenId); // address => tokenId
        }
        
        emit AddToReadDenylist(tokenId, toAddAddresses);
    }

    /**
     * @dev Self revoke read permission to a token
     */
    function selfAddToReadDenylist(uint256 tokenId) public {
        require(_exists(tokenId), "RehideNFT: Denylist set of nonexistent token");

        _noteReadDenylistAddresses[tokenId].push(_msgSender()); // tokenId => address
        _notesDeniedForAddress[_msgSender()].push(tokenId); // address => tokenId
        emit SelfAddToReadDenylist(tokenId, _msgSender());
    }

    /**
     * @dev Spam control - add to user specific blacklist
     */
    function addAddressesToBlacklist(address[] memory toAddAddresses) public {
        require(toAddAddresses.length > 0, "RehideNFT: No addresses to add");

        for (uint256 i = 0; i < toAddAddresses.length; i++) {
            _addressBlacklistForAddress[_msgSender()].push(toAddAddresses[i]); // user => spammer
            _addressBlacklistReportsCount[toAddAddresses[i]]++;
        }
        
        emit AddAddressesToBlacklist(_msgSender(), toAddAddresses);
    }

    /**
     * @dev Spam control - add to platform wide blacklist
     */
    function addAddressesToPlatformBlacklist(address[] memory toAddAddresses) external onlyOwner {
        require(toAddAddresses.length > 0, "RehideNFT: No addresses to add");

        for (uint256 i = 0; i < toAddAddresses.length; i++) {
            _addressBlacklistForPlatform.push(toAddAddresses[i]); // add spammer address
        }
        
        emit AddAddressesToPlatformBlacklist(toAddAddresses);
    }   

    function updateAllowListOnly(uint256 tokenId, uint256 allowListOnly) public {
        require(_exists(tokenId), "RehideNFT: Setting set of nonexistent token");
        require(ownerOf(tokenId) == _msgSender(), "RehideNFT: Trying to set another wallet's token setting");
        
        _notesMapping[tokenId].allowlistOnly = allowListOnly; 

        emit UpdateAllowListOnly(tokenId, allowListOnly);
    }

    function doMintNFT(address recipient, string memory uri) private returns (uint256) {
        _tokenIds.increment();

        uint256 newTokenId = _tokenIds.current();
        _safeMint(recipient, newTokenId);
        _setTokenURI(newTokenId, uri);

        emit TokenCreated(newTokenId, uri, recipient);

        return newTokenId;
    }

    function distributeReferrerRewards(address payable referrer) private {
        uint256 mintFee = msg.value;
        // If there are funds to distribute
        if (mintFee > 0) {
            uint256 totalTxReferrerRewards = 0;

            // If user's not trying to set referrer to self
            if (referrer != _msgSender()) {
                // Get current user's referrer
                address payable primaryReferrer = payable(_referrers[_msgSender()]);

                // If current user's referrer is empty, set it
                if (primaryReferrer == address(0) && referrer != address(0)) {
                    primaryReferrer = referrer;
                    _referrerIds.increment();
                    _referrers[_msgSender()] = referrer;
                    emit SetReferrer(_msgSender(), referrer);
                }

                // If current user's referrer is NOT empty, distribute
                if (primaryReferrer != address(0)) {
                    // Reward secondary referrers
                    address payable secondaryReferrer = primaryReferrer;
                    for (uint256 i = 0; i < _maxReferrerLevels; i++) {
                        secondaryReferrer = payable(_referrers[secondaryReferrer]);
                        if (secondaryReferrer == address(0) || secondaryReferrer == _msgSender()) {
                            break;
                        } else {
                            uint256 secondaryReferrerReward = mintFee.mul(_secondaryReferrerPercentage).div(100);
                            totalTxReferrerRewards += secondaryReferrerReward;
                            _referrerRewards[secondaryReferrer] += secondaryReferrerReward;
                            (bool secondaryReferrerSent, ) = secondaryReferrer.call{value: secondaryReferrerReward}("");
                            require(secondaryReferrerSent, "Failed to send Ether");
                            emit RewardsTransferred(secondaryReferrer, secondaryReferrerReward);
                        }
                    }

                    // Reward primary referrer
                    uint256 referrerTierId = _referrerTierList[primaryReferrer];
                    uint256 primaryReferrerReward = mintFee.mul(_primaryReferrerPercentage).div(100);

                    // Rebate based on tier
                    if (referrerTierId > 0) {
                        uint256 rebate = _tierRebate[referrerTierId];
                        uint256 whitelistReferrerReward = mintFee.mul(rebate).div(100);
                        primaryReferrerReward = whitelistReferrerReward;
                    }
                    totalTxReferrerRewards += primaryReferrerReward;
                    _referrerRewards[primaryReferrer] += primaryReferrerReward;
                    (bool primaryReferrerSent, ) = primaryReferrer.call{value: primaryReferrerReward}("");
                    require(primaryReferrerSent, "Failed to send Ether");
                    emit RewardsTransferred(primaryReferrer, primaryReferrerReward);
                }
            }
            uint256 maxReferrerRewards = mintFee.mul(_maxReferrerRewardsPercentage).div(100);
            require(totalTxReferrerRewards <= maxReferrerRewards, "RehideNFT: Unexpected rewards calculation result");
            _totalReferrerMintRewards += totalTxReferrerRewards;

            uint256 platformTxFee = mintFee - totalTxReferrerRewards;
            _totalPlatformMintFees += platformTxFee;
            (bool platformWalletSent, ) = _platformWallet.call{value: platformTxFee}("");
            require(platformWalletSent, "Failed to send Ether");
            emit RewardsTransferred(_platformWallet, platformTxFee);
        }
    }

    function setExpireNote(uint256 tokenId) private {
        require(_exists(tokenId), "RehideNFT: Nonexistent token");
        
        Note storage note = _notesMapping[tokenId];
        note.readsAvailable = 0;
        note.ttl = block.timestamp;
        note.package = "";
        
        emit SetExpireNote(tokenId);
    }

    function setTokenPackage(uint256 tokenId, string memory tokenPackage) private {
        require(_exists(tokenId), "RehideNFT: Package set of nonexistent token");

        _notesMapping[tokenId].package = tokenPackage;
        emit SetTokenPackage(tokenId, tokenPackage);
    }

    function updateTokenPackage(uint256 tokenId, string memory tokenPackage) public payable {
        require(_exists(tokenId), "RehideNFT: Package set of nonexistent token");
        require(ownerOf(tokenId) == _msgSender(), "RehideNFT: Trying to set another wallet's token package");
        
        setTokenPackage(tokenId, tokenPackage);

        uint256 fee = msg.value;
        if (fee > 0) {
            (bool platformWalletSent, ) = _platformWallet.call{value: fee}("");
            require(platformWalletSent, "Failed to send Ether");
            emit RewardsTransferred(_platformWallet, fee);
        }
    }

    function updateTokenURI(uint256 tokenId, string memory newUri) external onlyOwner {
        _setTokenURI(tokenId, newUri);
        emit UpdateTokenUri(tokenId, newUri);
    }

    function burn(uint256 tokenId) external {
        require(_exists(tokenId), "RehideNFT: Trying to burn nonexistent token");
        require(ownerOf(tokenId) == _msgSender(), "RehideNFT: Trying to burn another wallet's token");
        
        setExpireNote(tokenId);
        // setTokenPackage(tokenId, "");
        // delete _notesMapping[tokenId];

        _setTokenURI(tokenId, "");
        emit UpdateTokenUri(tokenId, "");

        _burn(tokenId);
        emit Burn(tokenId);
    }

    /**
     * @dev Get how many active mint passes are owned by address
     */
    function getWalletActiveMintPassCount(address account) external view returns (uint256 mintPassCount) {
        mintPassCount = getWalletActiveMintPass(account).length;
    }

    /**
     * @dev Get all active mint passes owned by address
     */
    function getWalletActiveMintPass(address account) public view returns (uint256[] memory tokenIds) {
        uint256 totalTokens = balanceOf(account);
        tokenIds = new uint256[](totalTokens);
        uint256 counter = 0;

        for (uint256 i = 0; i < totalTokens; i++) {
            uint256 tokenId = tokenOfOwnerByIndex(account, i);
            uint256 ttl = _passTtlMapping[tokenId];
            
            if (ttl == 0 || ttl > block.timestamp) {
                tokenIds[counter] = tokenId;
                counter++;
            }
        }
        
        // Resize the array to remove any unused elements
        assembly {
            mstore(tokenIds, counter)
        }
    }

    /**
     * @dev Get addresses that can read a token
     */
    function getNoteReadAllowlist(uint256 tokenId) external view returns (address[] memory addresses) {
        require(_exists(tokenId), "RehideNFT: Nonexistent token");
        addresses = _noteReadAllowlistAddresses[tokenId];
    }

    /**
     * @dev Get addresses that can't read a token
     */
    function getNoteReadDenylist(uint256 tokenId) external view returns (address[] memory addresses) {
        require(_exists(tokenId), "RehideNFT: Nonexistent token");

        addresses = _noteReadDenylistAddresses[tokenId];
    }

    /**
     * @dev Get how many tokens were created by address
     */
    function getWalletNotesCount(address account) external view returns (uint256 notesCount) {
        notesCount = _tokenIdsForAddress[account].length;
    }

    /**
     * @dev Get all tokens created by address
     */
    function getWalletNotes(address account) external view returns (uint256[] memory tokenIds) {
        tokenIds = _tokenIdsForAddress[account];
    }

    /**
     * @dev Get how many tokens an address can't read
     */
    function getNotesDeniedForAddressCount(address account) external view returns (uint256 notesCount) {
        notesCount = _notesDeniedForAddress[account].length;
    }

    /**
    * @dev Get all tokens that an address can't read (potentially used to be allowlist first)
    */
    function getNotesDeniedForAddress(address account) external view returns (uint256[] memory tokenIds) {
        tokenIds = _notesDeniedForAddress[account];
    }

    /**
    * @dev Get how many tokens are shared with an address
    */
    function getNotesSharedWithAddressCount(address account) external view returns (uint256 notesCount) {
        notesCount = _notesSharedWithAddress[account].length;
    }  

    /**
    * @dev Get all tokens shared with an address
    */
    function getTokensSharedWithAddress(address account) external view returns (uint256[] memory tokenIds) {
        tokenIds = _notesSharedWithAddress[account];
    }

    /**
     * @dev Spam control - check if address is in blacklist
     */
    function isAddressPlatformBlacklisted(address account) public view returns (bool) {
        for (uint256 i = 0; i < _addressBlacklistForPlatform.length; i++) {
            if (_addressBlacklistForPlatform[i] == account) {
                return true; 
            }
        }
        return false;
    }

    function getNoteReads(uint256 tokenId) external view returns (NoteRead[] memory tokenNoteReads) {
        require(_exists(tokenId), "RehideNFT: Nonexistent token");
        tokenNoteReads = _noteReads[tokenId];
    }

    function getWalletNoteReads(address account) external view returns (uint256[] memory walletNoteReads) {
        walletNoteReads = _addressReadNotes[account];
    }
}
