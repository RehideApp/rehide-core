// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./IRehideNFT.sol";
import "./RehideBase.sol";

contract RehideNFT is IRehideNFT, RehideBase {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    bool public _isPaused;
    bool public _isErc20Paused = true;

    /**
     * @dev Platform
     */
    address payable public _platformWallet;
    uint256 public _minEthMintPrice;
    uint256 public _readPlatformPercentage = 5;

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
    mapping(address => uint256) public _addressBlacklistReportsCount; // count reports
    address[] public _addressBlacklistForPlatform; // platform's blacklist

    /**
     * @dev Referrer Tiers
     */
    Counters.Counter public _tierCount;
    mapping(uint256 => uint256) public _tierRebate; 

    constructor(string memory name_, string memory symbol_, address platformWallet_, uint256 minEthMintPrice_) ERC721(name_, symbol_) {
        _platformWallet = payable(platformWallet_);
        _minEthMintPrice = minEthMintPrice_;
    }

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

    function togglePauseErc20() external onlyOwner {
        _isErc20Paused = !_isErc20Paused;
        emit TogglePauseErc20(_isErc20Paused, block.timestamp);
    }

    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }

    function setBaseURI(string memory uri) external onlyOwner {
        baseURI = uri;
        emit BatchMetadataUpdate(1, type(uint256).max);
    }

    function setTokenURI(uint256 tokenId, string memory tokenURI) internal {
        _setTokenURI(tokenId, tokenURI);
        emit MetadataUpdate(tokenId);
    }

    /**
     * @dev Set referral tier
     */
    function setTier(uint256 tierId, uint256 rebate) external onlyOwner {
        require(tierId > 0 && rebate <= _maxReferrerRewardsPercentage && rebate > 0, "X data");

        // If new tier (could be updating existing)
        if (_tierRebate[tierId] == 0) {
            _tierCount.increment();
        }

        _tierRebate[tierId] = rebate;
        emit SetTier(tierId, rebate);
    }

    function setMinEthMintPrice(uint256 minEthMintPrice) external onlyOwner {
        _minEthMintPrice = minEthMintPrice;
        emit SetMinEthMintPrice(_minEthMintPrice);
    }

    function setPlatformWallet(address payable platformWallet) external onlyOwner {
        require(platformWallet != address(0), "0 address");
        _platformWallet = platformWallet;
        emit SetPlatformWallet(_platformWallet);
    }

    function setReadPlatformPercentage(uint256 readPlatformPercentage) external onlyOwner {
        _readPlatformPercentage = readPlatformPercentage;
        emit SetReadPlatformPercentage(_readPlatformPercentage);
    }

    /**
     * @dev Link referrer and tier
     */
    function updateReferrerTierList(address[] calldata toUpdateAddresses, uint256 tierId) external onlyOwner {
        require(toUpdateAddresses.length > 0 && _tierRebate[tierId] > 0, "X data");

        for (uint256 i = 0; i < toUpdateAddresses.length; i++) {

            if (toUpdateAddresses[i] == address(0)){
                continue;
            }

            if (_referrerTierList[toUpdateAddresses[i]] == 0 && tierId > 0) {
                _referrerTierCount.increment();
            } else if (tierId == 0) {
                _referrerTierCount.decrement();
                emit RemoveFromReferrerTierList(toUpdateAddresses, tierId);
            }
            _referrerTierList[toUpdateAddresses[i]] = tierId;
        }
        emit UpdateReferrerTierList(toUpdateAddresses, tierId);
    }

    /**
     * @dev If ETH is transferred directly to contract
     */
    function withdraw() external nonReentrant onlyOwner returns (uint256) {
        uint256 balance = address(this).balance;

        if(balance > 0){
            (bool sent, ) = payable(owner()).call{value: balance}("");
            require(sent, "Failed to send Ether");
        }
        emit Withdraw(balance);
        return balance;
    }

    function mintPassWithERC20(
        address recipient, 
        string memory uri, 
        address payable referrer,
        uint256 ttl,
        uint256 erc20MintPrice,
        address erc20MintAddress)
        public payable returns (uint256) {

        require(!_isErc20Paused, "Paused");

        uint256 newTokenId = mintPass(recipient, uri, referrer, ttl);

        if(erc20MintPrice > 0) {
            uint256 allowance = IERC20(erc20MintAddress).allowance(_msgSender(), address(this));
            require(allowance >= erc20MintPrice, "X allowance");
            bool success = IERC20(erc20MintAddress).transferFrom(_msgSender(), _platformWallet, erc20MintPrice);
            require(success, "X ERC20");
            emit MintPassWithERC20(newTokenId, erc20MintPrice, erc20MintAddress);
        }

        return newTokenId;
    }

    function mintPassWithEth(
        address recipient, 
        string memory uri, 
        address payable referrer,
        uint256 ttl) 
        public payable returns (uint256) {

        // Enforce min price to non-owner and less than T3+ addresses (index 2) or already minted 1
        if (_msgSender() != owner() && (_referrerTierList[_msgSender()] < 2 || _tokenIdsForAddress[_msgSender()].length > 0)) { 
            require(msg.value >= _minEthMintPrice, "Too low");
        }

        return mintPass(recipient, uri, referrer, ttl);
    }

    function mintPass(
        address recipient, 
        string memory uri, 
        address payable referrer,
        uint256 ttl) 
        private whenNotPaused returns (uint256) {

        if (recipient == address(0)) {
            recipient = _msgSender();
        }

        uint256 newTokenId = doMintNFT(recipient, uri);
        emit MintNFT(newTokenId, uri, recipient, msg.value);

        require(newTokenId > 0, "Error minting");

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

        require(newTokenId > 0, "X minting");

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

    function readSharedNote(uint256 tokenId, uint256 platformFee) public nonReentrant payable {
        require(_exists(tokenId), "X ID");

        Note storage note = _notesMapping[tokenId];

        uint256 readFee = msg.value;
        if (_msgSender() != owner() && ownerOf(tokenId) != _msgSender()) {
            require(readFee >= note.readPrice, "X ETH");
        }

        if (note.allowlistOnly > 0) {
            bool isAllowed = false;
            for (uint256 i = 0; i < _noteReadAllowlistAddresses[tokenId].length; i++) {
                if (_msgSender() == _noteReadAllowlistAddresses[tokenId][i]) {
                    isAllowed = true;
                    break;
                }
            }
            require(isAllowed, "X allowlist");
        }

        if (_noteReadDenylistAddresses[tokenId].length > 0) {
            bool isDenied = false;
            for (uint256 i = 0; i < _noteReadDenylistAddresses[tokenId].length; i++) {
                if (_msgSender() == _noteReadDenylistAddresses[tokenId][i]) {
                    isDenied = true;
                    break;
                }
            }
            require(!isDenied, "In denylist");
        }

        NoteRead memory noteRead = NoteRead({
            reader: _msgSender(),
            timestamp: block.timestamp
        });
        
        _noteReads[tokenId].push(noteRead);
        _addressReadNotes[_msgSender()].push(tokenId);
        emit ReadSharedNote(tokenId, _msgSender(), block.timestamp);

        require(note.readsAvailable > 0, "X reads");
        require(note.ttl > block.timestamp, "Expired");
        
        note.readsAvailable -= 1;
        if (note.readsAvailable < 1){
            setExpireNote(tokenId);
            // delete _notesMapping[tokenId];
        }

        if (readFee > 0) {

            if (platformFee > 0) {
                _totalPlatformReadFees += platformFee;
                (bool platformTransferSuccess, ) = _platformWallet.call{value: platformFee}("");
                require(platformTransferSuccess, "X platform");
                emit ReadSharedNoteRewardsTransferred(_platformWallet, tokenId, platformFee);
            }

            address payable payableTokenOwner = payable(ownerOf(tokenId)); 
            uint256 tokenOwnerFee = readFee - platformFee;
            require(readFee >= tokenOwnerFee, "X royalty");
            _creatorReadFees[payableTokenOwner] += tokenOwnerFee;
            _totalCreatorsReadFees += tokenOwnerFee;
            (bool creatorTransferSuccess, ) = payableTokenOwner.call{value: tokenOwnerFee}("");
            require(creatorTransferSuccess, "X creator");
            emit ReadSharedNoteRewardsTransferred(payableTokenOwner, tokenId, tokenOwnerFee);
        }
    }

    /**
     * @dev To limit what addresses can read the note
     */
    function addToReadAllowlist(uint256 tokenId, address[] memory toAddAddresses) public {
        require(_exists(tokenId) && toAddAddresses.length > 0, "Not found");
        require(ownerOf(tokenId) == _msgSender(), "Unauthorised");

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
        require(_exists(tokenId), "Not found");
        require(ownerOf(tokenId) == _msgSender(), "Unauthorised");
        require(toAddAddresses.length > 0, "Empty");

        for (uint256 i = 0; i < toAddAddresses.length; i++) {
            if (toAddAddresses[i] != _msgSender()) { // only add if not self
                _noteReadDenylistAddresses[tokenId].push(toAddAddresses[i]); // tokenId => address
                _notesDeniedForAddress[toAddAddresses[i]].push(tokenId); // address => tokenId
            }
        }
        
        emit AddToReadDenylist(tokenId, toAddAddresses);
    }

    // /**
    //  * @dev Self revoke read permission to a token
    //  */
    // function selfAddToReadDenylist(uint256 tokenId) public {
    //     require(_exists(tokenId), "Not found");

    //     _noteReadDenylistAddresses[tokenId].push(_msgSender()); // tokenId => address
    //     _notesDeniedForAddress[_msgSender()].push(tokenId); // address => tokenId
    //     emit SelfAddToReadDenylist(tokenId, _msgSender());
    // }

    /**
     * @dev Spam control - add to user specific blacklist
     */
    function addAddressesToBlacklist(address[] memory toAddAddresses) public {
        require(toAddAddresses.length > 0, "Empty");

        for (uint256 i = 0; i < toAddAddresses.length; i++) {
            if (toAddAddresses[i] != _msgSender()) { // only add if not self
                _addressBlacklistForAddress[_msgSender()].push(toAddAddresses[i]); // user => spammer
                _addressBlacklistReportsCount[toAddAddresses[i]]++;
            }
        }
        
        emit AddAddressesToBlacklist(_msgSender(), toAddAddresses);
    }

    /**
     * @dev Spam control - add to platform wide blacklist
     */
    function addAddressesToPlatformBlacklist(address[] memory toAddAddresses) external onlyOwner {
        require(toAddAddresses.length > 0, "Empty");

        for (uint256 i = 0; i < toAddAddresses.length; i++) {
            if (toAddAddresses[i] != _msgSender()) { // only add if not self
                _addressBlacklistForPlatform.push(toAddAddresses[i]); // add spammer address
            }
        }
        
        emit AddAddressesToPlatformBlacklist(toAddAddresses);
    }   

    function updateAllowListOnly(uint256 tokenId, uint256 allowListOnly) public {
        require(_exists(tokenId), "Not found");
        require(ownerOf(tokenId) == _msgSender(), "Unauthorised");
        
        _notesMapping[tokenId].allowlistOnly = allowListOnly; 

        emit UpdateAllowListOnly(tokenId, allowListOnly);
    }

    function doMintNFT(address recipient, string memory uri) private nonReentrant returns (uint256) {
        _tokenIds.increment();

        uint256 newTokenId = _tokenIds.current();
        _safeMint(recipient, newTokenId);
        setTokenURI(newTokenId, uri);

        emit TokenCreated(newTokenId, uri, recipient);

        return newTokenId;
    }

    function distributeReferrerRewards(address payable referrer) private nonReentrant {
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
                            require(secondaryReferrerSent, "Ether failed");
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
                    require(primaryReferrerSent, "Ether failed");
                    emit RewardsTransferred(primaryReferrer, primaryReferrerReward);
                }
            }
            uint256 maxReferrerRewards = mintFee.mul(_maxReferrerRewardsPercentage).div(100);
            require(totalTxReferrerRewards <= maxReferrerRewards, "Unexpected result");
            _totalReferrerMintRewards += totalTxReferrerRewards;

            uint256 platformTxFee = mintFee - totalTxReferrerRewards;
            _totalPlatformMintFees += platformTxFee;
            (bool platformWalletSent, ) = _platformWallet.call{value: platformTxFee}("");
            require(platformWalletSent, "Ether failed");
            emit RewardsTransferred(_platformWallet, platformTxFee);
        }
    }

    function setExpireNote(uint256 tokenId) private {
        require(_exists(tokenId), "Not found");
        
        Note storage note = _notesMapping[tokenId];
        note.readsAvailable = 0;
        note.ttl = block.timestamp;
        note.package = "";
        
        emit SetExpireNote(tokenId);
    }

    function setTokenPackage(uint256 tokenId, string memory tokenPackage) private {
        require(_exists(tokenId), "Not found");

        _notesMapping[tokenId].package = tokenPackage;
        emit SetTokenPackage(tokenId, tokenPackage);
    }

    function updateTokenPackage(uint256 tokenId, string memory tokenPackage) public nonReentrant payable {
        require(_exists(tokenId), "Not found");
        require(ownerOf(tokenId) == _msgSender(), "Unauthorised");
        
        setTokenPackage(tokenId, tokenPackage);

        uint256 fee = msg.value;
        if (fee > 0) {
            (bool platformWalletSent, ) = _platformWallet.call{value: fee}("");
            require(platformWalletSent, "Ether failed");
            emit RewardsTransferred(_platformWallet, fee);
        }
    }

    function updateTokenURI(uint256 tokenId, string memory newUri) external onlyOwner {
        setTokenURI(tokenId, newUri);
    }

    function burn(uint256 tokenId) external {
        require(_exists(tokenId), "Not found");
        require(ownerOf(tokenId) == _msgSender() || _msgSender() == owner(), "Unauthorised");
        
        setExpireNote(tokenId);
        // setTokenPackage(tokenId, "");
        // delete _notesMapping[tokenId];

        setTokenURI(tokenId, "");

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
        require(_exists(tokenId), "Not found");
        addresses = _noteReadAllowlistAddresses[tokenId];
    }

    /**
     * @dev Get addresses that can't read a token
     */
    function getNoteReadDenylist(uint256 tokenId) external view returns (address[] memory addresses) {
        require(_exists(tokenId), "Not found");
        addresses = _noteReadDenylistAddresses[tokenId];
    }

    /**
     * @dev Get how many addresses an address has blacklisted
     */
    function getAddressBlacklistForAddressCount(address account) external view returns (uint256 addressCount) {
        addressCount = _addressBlacklistForAddress[account].length;
    }

    /**
    * @dev Get all addresses that an address has blacklisted
    */
    function getAddressBlacklistForAddress(address account) external view returns (address[] memory addresses) {
        addresses = _addressBlacklistForAddress[account];
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
        require(_exists(tokenId), "Not found");
        tokenNoteReads = _noteReads[tokenId];
    }

    function getWalletNoteReads(address account) external view returns (uint256[] memory walletNoteReads) {
        walletNoteReads = _addressReadNotes[account];
    }
}
