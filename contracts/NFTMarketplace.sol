// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721ReceiverUpgradeable.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/introspection/ERC165Checker.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import "abdk-libraries-solidity/ABDKMath64x64.sol";

// *****************************************************************************
// *** NOTE: almost all uses of _tokenAddress in this contract are UNSAFE!!! ***
// *****************************************************************************
contract NFTMarketplace is
    IERC721ReceiverUpgradeable,
    Initializable,
    AccessControlUpgradeable
{
    using SafeMath for uint256;
    using ABDKMath64x64 for int128;
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    bytes4 private constant _INTERFACE_ID_ERC721 = 0x80ac58cd;

    bytes32 public constant MARKET_ADMIN = keccak256("MARKET_ADMIN");

    // ############
    // Initializer
    // ############
    function initialize(
        address _taxRecipient
    )
        public
        initializer
    {
        __AccessControl_init();

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);

        taxRecipient = _taxRecipient;
        defaultTax = ABDKMath64x64.divu(1, 40); // 2.5%
    }

    struct Listing {
        address seller;
        uint256 price;
        IERC20Upgradeable currency;
        uint256 startingTime;
        uint256 expirationTime;
        bool isEnableOffering;
    }

    // ############
    // State
    // ############
    address public taxRecipient;

    mapping(address => mapping(uint256 => Listing)) private listings;
    mapping(address => EnumerableSet.UintSet) private listedTokenIDs;
    EnumerableSet.AddressSet private listedTokenTypes; // stored for a way to know the types we have on offer

    mapping(address => bool) public isUserBanned;

    mapping(address => int128) public tax; // per NFT type tax
    mapping(address => bool) private freeTax;
    int128 public defaultTax; // fallback in case we haven't specified it

    EnumerableSet.AddressSet private allowedTokenTypes;

    EnumerableSet.AddressSet private allowedCurrencies;

    struct PackListing {
        uint256[] items;
        address seller;
        uint256 price;
        IERC20Upgradeable currency;
        uint256 startingTime;
        uint256 expirationTime;
    }

    uint256 private packCounter;

    mapping(address => mapping(uint256 => PackListing)) private packListings;
    mapping(address => EnumerableSet.UintSet) private listedPackIDs;
    mapping(address => EnumerableSet.UintSet) private packListedTokenIDs;

    struct Offer {
        IERC20Upgradeable currency;
        uint256 price;
        uint256 expirationTime;
    }

    // NFT collection => token ID => offerers
    mapping(address => mapping(uint256 => EnumerableSet.AddressSet)) private offerers;
    // NFT collection => token ID => offerer => offer
    mapping(address => mapping(uint256 => mapping(address => Offer))) private offers;

    // ############
    // Events
    // ############
    event NewListing(
        address indexed seller,
        IERC721 indexed nftAddress,
        uint256 indexed nftID,
        uint256 price,
        IERC20Upgradeable currency,
        uint256 startingTime,
        uint256 expirationTime,
        bool isEnableOffering
    );
    event NewPackListing(
        address indexed seller,
        IERC721 indexed nftAddress,
        uint256 indexed packID,
        uint256[] items,
        uint256 price,
        IERC20Upgradeable currency,
        uint256 startingTime,
        uint256 expirationTime
    );
    event ListingDetailChange(
        address indexed seller,
        IERC721 indexed nftAddress,
        uint256 indexed nftID,
        uint256 newPrice,
        IERC20Upgradeable newCurrency,
        uint256 newStartingTime,
        uint256 newExpirationTime,
        bool isEnableOffering
    );
    event PackListingDetailChange(
        address indexed seller,
        IERC721 indexed nftAddress,
        uint256 indexed packID,
        uint256 newPrice,
        IERC20Upgradeable newCurrency,
        uint256 newStartingTime,
        uint256 newExpirationTime
    );
    event CancelledListing(
        address indexed seller,
        IERC721 indexed nftAddress,
        uint256 indexed nftID
    );
    event CancelledPackListing(
        address indexed seller,
        IERC721 indexed nftAddress,
        uint256 indexed packID
    );
    event PurchasedListing(
        address indexed buyer,
        address seller,
        IERC721 indexed nftAddress,
        uint256 indexed nftID,
        uint256 price,
        IERC20Upgradeable currency
    );
    event PurchasedPackListing(
        address indexed buyer,
        address seller,
        IERC721 indexed nftAddress,
        uint256 indexed packID,
        uint256 price,
        IERC20Upgradeable currency
    );
    event OfferListing(
        address indexed offerer,
        IERC721 indexed nftAddress,
        uint256 indexed nftID,
        IERC20Upgradeable currency,
        uint256 price,
        uint256 expirationTime
    );
    // event OfferListingChange(
    //     address indexed offerer,
    //     IERC721 indexed nftAddress,
    //     uint256 indexed nftID,
    //     IERC20Upgradeable newCurrency,
    //     uint256 newPrice
    // );
    event CancelOfferListing(
        address offerer,
        IERC721 indexed nftAddress,
        uint256 indexed nftID
    );
    event AcceptOfferListing(
        address indexed seller,
        address offerer,
        IERC721 indexed nftAddress,
        uint256 indexed nftID,
        IERC20Upgradeable currency,
        uint256 finalPrice
    );

    // ############
    // Modifiers
    // ############
    modifier restricted() {
        require(hasRole(MARKET_ADMIN, msg.sender), "Not admin");
        _;
    }

    modifier isListed(IERC721 _tokenAddress, uint256 id) {
        _isListed(_tokenAddress, id);
        _;
    }

    modifier isMultiListed(IERC721 _tokenAddress, uint256[] memory ids) {
        for (uint256 i = 0; i < ids.length; i++) {
            _isListed(_tokenAddress, ids[i]);
        }
        _;
    }

    function _isListed(IERC721 _tokenAddress, uint256 id) internal view {
        require(
            listedTokenTypes.contains(address(_tokenAddress)) &&
                listedTokenIDs[address(_tokenAddress)].contains(id),
            "Token ID not listed"
        );
    }

    modifier isPackListed(IERC721 _tokenAddress, uint256 packId) {
        _isPackListed(_tokenAddress, packId);
        _;
    }

    function _isPackListed(IERC721 _tokenAddress, uint256 packId) internal view {
        require(
            listedTokenTypes.contains(address(_tokenAddress)) &&
                listedPackIDs[address(_tokenAddress)].contains(packId),
            "Pack ID not listed"
        );
    }

    modifier isListedOnPack(IERC721 _tokenAddress, uint256 id) {
        _isListedOnPack(_tokenAddress, id);
        _;
    }

    modifier isMultiListedOnPack(IERC721 _tokenAddress, uint256[] memory ids) {
        for (uint256 i = 0; i < ids.length; i++) {
            _isListedOnPack(_tokenAddress, ids[i]);
        }
        _;
    }

    function _isListedOnPack(IERC721 _tokenAddress, uint256 id) internal view {
        require(
            listedTokenTypes.contains(address(_tokenAddress)) &&
                packListedTokenIDs[address(_tokenAddress)].contains(id),
            "Token ID not listed"
        );
    }

    modifier isNotListed(IERC721 _tokenAddress, uint256 id) {
        _isNotListed(_tokenAddress, id);
        _;
    }

    modifier isMultiNotListed(IERC721 _tokenAddress, uint256[] memory ids) {
        for (uint256 i = 0; i < ids.length; i++) {
            _isNotListed(_tokenAddress, ids[i]);
        }
        _;
    }

    function _isNotListed(IERC721 _tokenAddress, uint256 id) public view {
        require(
            !listedTokenTypes.contains(address(_tokenAddress)) ||
                !listedTokenIDs[address(_tokenAddress)].contains(id),
            "Token ID must not be listed"
        );
    }

    modifier isPackNotListed(IERC721 _tokenAddress, uint256 packId) {
        _isPackNotListed(_tokenAddress, packId);
        _;
    }

    function _isPackNotListed(IERC721 _tokenAddress, uint256 packId) internal view {
        require(
            !listedTokenTypes.contains(address(_tokenAddress)) ||
                !listedPackIDs[address(_tokenAddress)].contains(packId),
            "Pack ID must not be listed"
        );
    }

    modifier isNotListedOnPack(IERC721 _tokenAddress, uint256 id) {
        _isNotListedOnPack(_tokenAddress, id);
        _;
    }

    modifier isMultiNotListedOnPack(IERC721 _tokenAddress, uint256[] memory ids) {
        for (uint256 i = 0; i < ids.length; i++) {
            _isNotListedOnPack(_tokenAddress, ids[i]);
        }
        _;
    }

    function _isNotListedOnPack(IERC721 _tokenAddress, uint256 id) public view {
        require(
            !listedTokenTypes.contains(address(_tokenAddress)) ||
                !packListedTokenIDs[address(_tokenAddress)].contains(id),
            "Token ID must not be listed"
        );
    }

    modifier isSeller(IERC721 _tokenAddress, uint256 id) {
        _isSeller(_tokenAddress, id);
        _;
    }

    function _isSeller(IERC721 _tokenAddress, uint256 id) internal view {
        require(
            listings[address(_tokenAddress)][id].seller == msg.sender,
            "Access denied"
        );
    }

    modifier isPackSeller(IERC721 _tokenAddress, uint256 packId) {
        _isPackSeller(_tokenAddress, packId);
        _;
    }

    function _isPackSeller(IERC721 _tokenAddress, uint256 packId) internal view {
        require(
            packListings[address(_tokenAddress)][packId].seller == msg.sender,
            "Access denied"
        );
    }

    modifier isSellerOrAdmin(IERC721 _tokenAddress, uint256 id) {
        _isSellerOrAdmin(_tokenAddress, id);
        _;
    }

    function _isSellerOrAdmin(IERC721 _tokenAddress, uint256 id) internal view {
        require(
            listings[address(_tokenAddress)][id].seller == msg.sender ||
                hasRole(MARKET_ADMIN, msg.sender),
            "Access denied"
        );
    }

    modifier isPackSellerOrAdmin(IERC721 _tokenAddress, uint256 packId) {
        _isPackSellerOrAdmin(_tokenAddress, packId);
        _;
    }

    function _isPackSellerOrAdmin(IERC721 _tokenAddress, uint256 packId) internal view {
        require(
            packListings[address(_tokenAddress)][packId].seller == msg.sender ||
                hasRole(MARKET_ADMIN, msg.sender),
            "Access denied"
        );
    }

    modifier tokenNotBanned(IERC721 _tokenAddress) {
        _tokenNotBanned(_tokenAddress);
        _;
    }

    function _tokenNotBanned(IERC721 _tokenAddress) public view {
        require(
            isTokenAllowed(_tokenAddress),
            "This type of NFT may not be traded here"
        );
    }

    modifier userNotBanned() {
        require(isUserBanned[msg.sender] == false, "Forbidden access");
        _;
    }

    modifier isValidERC721(IERC721 _tokenAddress) {
        _isValidERC721(_tokenAddress);
        _;
    }

    function _isValidERC721(IERC721 _tokenAddress) internal view {
        require(
            ERC165Checker.supportsInterface(
                address(_tokenAddress),
                _INTERFACE_ID_ERC721
            )
        );
    }

    modifier onlyNonContract() {
        _onlyNonContract();
        _;
    }

    function _onlyNonContract() internal view {
        require(tx.origin == msg.sender, "Contract forbidden");
    }

    modifier isAllowedCurrency(IERC20Upgradeable _currency) {
        _isAllowedCurrency(_currency);
        _;
    }

    function _isAllowedCurrency(IERC20Upgradeable _currency) internal view {
        require(allowedCurrencies.contains(address(_currency)), "Not allowed currencies");
    }

    modifier isValidTime(uint256 _startingTime, uint256 _expirationTime) {
        _isValidTime(_startingTime, _expirationTime);
        _;
    }

    function _isValidTime(uint256 _startingTime, uint256 _expirationTime) internal view {
        require(block.timestamp < _expirationTime && _startingTime < _expirationTime, "Invalid time");
    }

    modifier fieldsValidation(
        IERC721 _tokenAddress,
        IERC20Upgradeable _currency,
        uint256 _startingTime,
        uint256 _expirationTime
    ) {
        _fieldsValidation(
            _tokenAddress,
            _currency,
            _startingTime,
            _expirationTime
        );
        _;
    }

    function _fieldsValidation(
        IERC721 _tokenAddress,
        IERC20Upgradeable _currency,
        uint256 _startingTime,
        uint256 _expirationTime
    ) internal view {
        _tokenNotBanned(_tokenAddress);
        _isValidERC721(_tokenAddress);
        _isAllowedCurrency(_currency);
        _isValidTime(_startingTime, _expirationTime);
    }

    // ############
    // Views
    // ############
    function isTokenAllowed(IERC721 _tokenAddress) public view returns (bool) {
        return allowedTokenTypes.contains(address(_tokenAddress));
    }

    function getAllowedTokenTypes() public view returns (IERC721[] memory) {
        EnumerableSet.AddressSet storage set = allowedTokenTypes;
        IERC721[] memory tokens = new IERC721[](set.length());

        for (uint256 i = 0; i < tokens.length; i++) {
            tokens[i] = IERC721(set.at(i));
        }
        return tokens;
    }

    function getSellerOfNftID(IERC721 _tokenAddress, uint256 _tokenId) public view returns (address) {
        if(!listedTokenTypes.contains(address(_tokenAddress))) {
            return address(0);
        }

        if(!listedTokenIDs[address(_tokenAddress)].contains(_tokenId)) {
            return address(0);
        }

        return listings[address(_tokenAddress)][_tokenId].seller;
    }

    function getSellerOfPackID(IERC721 _tokenAddress, uint256 _packId) public view returns (address) {
        if(!listedTokenTypes.contains(address(_tokenAddress))) {
            return address(0);
        }

        if(!listedPackIDs[address(_tokenAddress)].contains(_packId)) {
            return address(0);
        }

        return packListings[address(_tokenAddress)][_packId].seller;
    }

    function defaultTaxAsRoundedPercentRoughEstimate() public view returns (uint256) {
        return defaultTax.mulu(100);
    }

    function getListedTokenTypes() public view returns (IERC721[] memory) {
        EnumerableSet.AddressSet storage set = listedTokenTypes;
        IERC721[] memory tokens = new IERC721[](set.length());

        for (uint256 i = 0; i < tokens.length; i++) {
            tokens[i] = IERC721(set.at(i));
        }
        return tokens;
    }

    function getListingIDs(IERC721 _tokenAddress)
        public
        view
        returns (uint256[] memory)
    {
        EnumerableSet.UintSet storage set = listedTokenIDs[address(_tokenAddress)];
        uint256[] memory tokens = new uint256[](set.length());

        for (uint256 i = 0; i < tokens.length; i++) {
            tokens[i] = set.at(i);
        }
        return tokens;
    }

    function getPackListingIDs(IERC721 _tokenAddress)
        public
        view
        returns (uint256[] memory)
    {
        EnumerableSet.UintSet storage set = listedPackIDs[address(_tokenAddress)];
        uint256[] memory packs = new uint256[](set.length());

        for (uint256 i = 0; i < packs.length; i++) {
            packs[i] = set.at(i);
        }
        return packs;
    }

    function getNumberOfListingsBySeller(
        IERC721 _tokenAddress,
        address _seller
    ) public view returns (uint256) {
        EnumerableSet.UintSet storage listedTokens = listedTokenIDs[address(_tokenAddress)];

        uint256 amount = 0;
        for (uint256 i = 0; i < listedTokens.length(); i++) {
            if (
                listings[address(_tokenAddress)][listedTokens.at(i)].seller == _seller
            ) amount++;
        }

        return amount;
    }

    function getNumberOfPackListingsBySeller(
        IERC721 _tokenAddress,
        address _seller
    ) public view returns (uint256) {
        EnumerableSet.UintSet storage listedPacks = listedPackIDs[address(_tokenAddress)];

        uint256 amount = 0;
        for (uint256 i = 0; i < listedPacks.length(); i++) {
            if (
                packListings[address(_tokenAddress)][listedPacks.at(i)].seller == _seller
            ) amount++;
        }

        return amount;
    }

    function getListingIDsBySeller(IERC721 _tokenAddress, address _seller)
        public
        view
        returns (uint256[] memory tokens)
    {
        // NOTE: listedTokens is enumerated twice (once for length calc, once for getting token IDs)
        uint256 amount = getNumberOfListingsBySeller(_tokenAddress, _seller);
        tokens = new uint256[](amount);

        EnumerableSet.UintSet storage listedTokens = listedTokenIDs[address(_tokenAddress)];

        uint256 index = 0;
        for (uint256 i = 0; i < listedTokens.length(); i++) {
            uint256 id = listedTokens.at(i);
            if (listings[address(_tokenAddress)][id].seller == _seller)
                tokens[index++] = id;
        }

        return tokens;
    }

    function getPackListingIDsBySeller(IERC721 _tokenAddress, address _seller)
        public
        view
        returns (uint256[] memory packs)
    {
        // NOTE: listedTokens is enumerated twice (once for length calc, once for getting token IDs)
        uint256 amount = getNumberOfPackListingsBySeller(_tokenAddress, _seller);
        packs = new uint256[](amount);

        EnumerableSet.UintSet storage listedPacks = listedPackIDs[address(_tokenAddress)];

        uint256 index = 0;
        for (uint256 i = 0; i < listedPacks.length(); i++) {
            uint256 packId = listedPacks.at(i);
            if (packListings[address(_tokenAddress)][packId].seller == _seller)
                packs[index++] = packId;
        }

        return packs;
    }

    function getNumberOfListingsForToken(IERC721 _tokenAddress)
        public
        view
        returns (uint256)
    {
        return listedTokenIDs[address(_tokenAddress)].length();
    }

    function getNumberOfPackListingsForToken(IERC721 _tokenAddress)
        public
        view
        returns (uint256)
    {
        return listedPackIDs[address(_tokenAddress)].length();
    }

    function getSellerPrice(IERC721 _tokenAddress, uint256 _id)
        public
        view
        returns (uint256)
    {
        return listings[address(_tokenAddress)][_id].price;
    }

    function getPackSellerPrice(IERC721 _tokenAddress, uint256 _packId)
        public
        view
        returns (uint256)
    {
        return packListings[address(_tokenAddress)][_packId].price;
    }

    function getSellerCurrency(IERC721 _tokenAddress, uint256 _id)
        public
        view
        returns (IERC20Upgradeable)
    {
        return listings[address(_tokenAddress)][_id].currency;
    }

    function getPackSellerCurrency(IERC721 _tokenAddress, uint256 _packId)
        public
        view
        returns (IERC20Upgradeable)
    {
        return packListings[address(_tokenAddress)][_packId].currency;
    }

    function getSellerTimestamp(IERC721 _tokenAddress, uint256 _id)
        public
        view
        returns (uint256, uint256)
    {
        return (
            listings[address(_tokenAddress)][_id].startingTime,
            listings[address(_tokenAddress)][_id].expirationTime
        );
    }

    function getPackSellerTimestamp(IERC721 _tokenAddress, uint256 _packId)
        public
        view
        returns (uint256, uint256)
    {
        return (
            packListings[address(_tokenAddress)][_packId].startingTime,
            packListings[address(_tokenAddress)][_packId].expirationTime
        );
    }

    function getFinalPrice(IERC721 _tokenAddress, uint256 _id)
        public
        view
        returns (uint256, IERC20Upgradeable)
    {
        return
            (
                getSellerPrice(_tokenAddress, _id).add(
                    getTaxOnListing(_tokenAddress, _id)
                ),
                getSellerCurrency(_tokenAddress, _id)
            );
    }

    function getPackFinalPrice(IERC721 _tokenAddress, uint256 _packId)
        public
        view
        returns (uint256, IERC20Upgradeable)
    {
        return
            (
                getPackSellerPrice(_tokenAddress, _packId).add(
                    getPackTaxOnListing(_tokenAddress, _packId)
                ),
                getPackSellerCurrency(_tokenAddress, _packId)
            );
    }

    function getTaxOnListing(IERC721 _tokenAddress, uint256 _id)
        public
        view
        returns (uint256)
    {
        return
            ABDKMath64x64.mulu(
                tax[address(_tokenAddress)],
                getSellerPrice(_tokenAddress, _id)
            );
    }

    function getPackTaxOnListing(IERC721 _tokenAddress, uint256 _packId)
        public
        view
        returns (uint256)
    {
        return
            ABDKMath64x64.mulu(
                tax[address(_tokenAddress)],
                getPackSellerPrice(_tokenAddress, _packId)
            );
    }

    function getTokensOnPack(IERC721 _tokenAddress, uint256 _packId)
        public
        view
        returns (uint256[] memory)
    {
        return packListings[address(_tokenAddress)][_packId].items;
    }

    function getIsEnableOffering(IERC721 _tokenAddress, uint256 _id) public view returns (bool) {
        return listings[address(_tokenAddress)][_id].isEnableOffering;
    }

    function getOfferersByOrder(IERC721 _tokenAddress, uint256 _id)
        public
        view
        returns(address[] memory)
    {
        EnumerableSet.AddressSet storage set = offerers[address(_tokenAddress)][_id];
        address[] memory _offerers = new address[](set.length());

        for (uint256 i = 0; i < _offerers.length; i++) {
            _offerers[i] = address(set.at(i));
        }
        return _offerers;
    }

    function getOfferDetail(IERC721 _tokenAddress, uint256 _id, address _offerer)
        public
        view
        returns(IERC20Upgradeable currency, uint256 price, uint256 expirationTime)
    {
        currency = offers[address(_tokenAddress)][_id][_offerer].currency;
        price = offers[address(_tokenAddress)][_id][_offerer].price;
        expirationTime = offers[address(_tokenAddress)][_id][_offerer].expirationTime;
    }

    function getOfferTax(IERC721 _tokenAddress, uint256 _id, address _offerer) public view returns(uint256) {
        (, uint256 price,) = getOfferDetail(_tokenAddress, _id, _offerer);

        return ABDKMath64x64.mulu(
            tax[address(_tokenAddress)],
            price
        );
    }

    function getOfferFinalPrice(IERC721 _tokenAddress, uint256 _id, address _offerer) public view returns(uint256, IERC20Upgradeable) {
        (IERC20Upgradeable currency, uint256 price,) = getOfferDetail(_tokenAddress, _id, _offerer);

        return (
            price.add(
                getOfferTax(_tokenAddress, _id, _offerer)
            ),
            currency
        );
    }

    // ############
    // Mutative
    // ############
    function _addListing(
        IERC721 _tokenAddress,
        uint256 _id,
        uint256 _price,
        IERC20Upgradeable _currency,
        uint256 _startingTime,
        uint256 _expirationTime,
        bool _isEnableOffering
    ) internal {
        listings[address(_tokenAddress)][_id] = Listing(
            msg.sender,
            _price,
            _currency,
            _startingTime,
            _expirationTime,
            _isEnableOffering
        );
        listedTokenIDs[address(_tokenAddress)].add(_id);

        _updateListedTokenTypes(_tokenAddress);

        // in theory the transfer and required approval already test non-owner operations
        _tokenAddress.safeTransferFrom(msg.sender, address(this), _id);

        emit NewListing(
            msg.sender,
            _tokenAddress,
            _id,
            _price,
            _currency,
            _startingTime,
            _expirationTime,
            _isEnableOffering
        );
    }

    function addListing(
        IERC721 _tokenAddress,
        uint256 _id,
        uint256 _price,
        IERC20Upgradeable _currency,
        uint256 _startingTime,
        uint256 _expirationTime,
        bool _isEnableOffering
    )
        public
        userNotBanned
        isNotListed(_tokenAddress, _id)
        isNotListedOnPack(_tokenAddress, _id)
        fieldsValidation(_tokenAddress, _currency, _startingTime, _expirationTime)
    {
        _addListing(
            _tokenAddress,
            _id,
            _price,
            _currency,
            _startingTime,
            _expirationTime,
            _isEnableOffering
        );
    }

    function _addPackListing (
        IERC721 _tokenAddress,
        uint256[] memory _ids,
        uint256 _price,
        IERC20Upgradeable _currency,
        uint256 _startingTime,
        uint256 _expirationTime
    ) internal {
        uint256 packId = packCounter;
        packListings[address(_tokenAddress)][packId] = PackListing(
            _ids,
            msg.sender,
            _price,
            _currency,
            _startingTime,
            _expirationTime
        );
        listedPackIDs[address(_tokenAddress)].add(packId);

        for (uint256 i = 0; i < _ids.length; i++) {
            // add items to listed
            packListedTokenIDs[address(_tokenAddress)].add(_ids[i]);
            // in theory the transfer and required approval already test non-owner operations
            _tokenAddress.safeTransferFrom(msg.sender, address(this), _ids[i]);
        }

        _updateListedTokenTypes(_tokenAddress);

        packCounter = packCounter.add(1);

        emit NewPackListing(
            msg.sender,
            _tokenAddress, 
            packId,
            _ids, 
            _price,
            _currency,
            _startingTime,
            _expirationTime
        );
    }

    function addPackListing(
        IERC721 _tokenAddress,
        uint256[] memory _ids,
        uint256 _price,
        IERC20Upgradeable _currency,
        uint256 _startingTime,
        uint256 _expirationTime
    )
        external
        userNotBanned
        isMultiNotListed(_tokenAddress, _ids)
        isMultiNotListedOnPack(_tokenAddress, _ids)
        fieldsValidation(_tokenAddress, _currency, _startingTime, _expirationTime)
    {
        _addPackListing(
            _tokenAddress,
            _ids,
            _price,
            _currency,
            _startingTime,
            _expirationTime
        );
    }

    function _changeListingDetail(
        IERC721 _tokenAddress,
        uint256 _id,
        uint256 _newPrice,
        IERC20Upgradeable _newCurrency,
        uint256 _newStartingTime,
        uint256 _newExpirationTime,
        bool _isEnableOffering
    ) internal {
        listings[address(_tokenAddress)][_id].price = _newPrice;
        listings[address(_tokenAddress)][_id].currency = _newCurrency;
        listings[address(_tokenAddress)][_id].startingTime = _newStartingTime;
        listings[address(_tokenAddress)][_id].expirationTime = _newExpirationTime;
        listings[address(_tokenAddress)][_id].isEnableOffering = _isEnableOffering;
    }

    function changeListingDetail(
        IERC721 _tokenAddress,
        uint256 _id,
        uint256 _newPrice,
        IERC20Upgradeable _newCurrency,
        uint256 _newStartingTime,
        uint256 _newExpirationTime,
        bool _isEnableOffering
    )
        public
        userNotBanned
        isListed(_tokenAddress, _id)
        isSeller(_tokenAddress, _id)
        isAllowedCurrency(_newCurrency)
        isValidTime(_newStartingTime, _newExpirationTime)
    {
        _changeListingDetail(
            _tokenAddress,
            _id,
            _newPrice,
            _newCurrency,
            _newStartingTime,
            _newExpirationTime,
            _isEnableOffering
        );

        emit ListingDetailChange(
            msg.sender,
            _tokenAddress,
            _id,
            _newPrice,
            _newCurrency,
            _newStartingTime,
            _newExpirationTime,
            _isEnableOffering
        );
    }

    function changePackListingDetail(
        IERC721 _tokenAddress,
        uint256 _packId,
        uint256 _newPrice,
        IERC20Upgradeable _newCurrency,
        uint256 _newStartingTime,
        uint256 _newExpirationTime
    )
        external
        userNotBanned
        isPackListed(_tokenAddress, _packId)
        isPackSeller(_tokenAddress, _packId)
        isAllowedCurrency(_newCurrency)
        isValidTime(_newStartingTime, _newExpirationTime)
    {
        packListings[address(_tokenAddress)][_packId].price = _newPrice;
        packListings[address(_tokenAddress)][_packId].currency = _newCurrency;
        packListings[address(_tokenAddress)][_packId].startingTime = _newStartingTime;
        packListings[address(_tokenAddress)][_packId].expirationTime = _newExpirationTime;

        emit PackListingDetailChange(
            msg.sender,
            _tokenAddress,
            _packId,
            _newPrice,
            _newCurrency,
            _newStartingTime,
            _newExpirationTime
        );
    }

    function cancelListing(IERC721 _tokenAddress, uint256 _id)
        public
        userNotBanned
        isListed(_tokenAddress, _id)
        isSellerOrAdmin(_tokenAddress, _id)
    {
        address seller = listings[address(_tokenAddress)][_id].seller;

        delete listings[address(_tokenAddress)][_id];
        listedTokenIDs[address(_tokenAddress)].remove(_id);

        _clearOffers(_tokenAddress, _id);

        _updateListedTokenTypes(_tokenAddress);

        _tokenAddress.safeTransferFrom(address(this), seller, _id);

        emit CancelledListing(seller, _tokenAddress, _id);
    }

    function cancelPackListing(IERC721 _tokenAddress, uint256 _packId)
        external
        userNotBanned
        isPackListed(_tokenAddress, _packId)
        isPackSellerOrAdmin(_tokenAddress, _packId)
    {
        address seller = packListings[address(_tokenAddress)][_packId].seller;
        uint256[] memory items = packListings[address(_tokenAddress)][_packId].items;

        delete packListings[address(_tokenAddress)][_packId];
        listedPackIDs[address(_tokenAddress)].remove(_packId);

        for (uint256 i = 0; i < items.length; i++) {
            packListedTokenIDs[address(_tokenAddress)].remove(items[i]);
            _tokenAddress.safeTransferFrom(address(this), seller, items[i]);
        }

        _updateListedTokenTypes(_tokenAddress);

        emit CancelledPackListing(seller, _tokenAddress, _packId);
    }

    function purchaseListing(
        IERC721 _tokenAddress,
        uint256 _id,
        uint256 _maxPrice,
        IERC20Upgradeable _currency
    )
        public
        userNotBanned
        isListed(_tokenAddress, _id)
    {
        (uint256 finalPrice,) = getFinalPrice(_tokenAddress, _id);
        require(finalPrice <= _maxPrice, "Buying price too low");

        Listing memory listing = listings[address(_tokenAddress)][_id];
        require(isUserBanned[listing.seller] == false, "Banned seller");
        require(block.timestamp >= listing.startingTime, "The order has not yet started");
        require(block.timestamp <= listing.expirationTime, "The order has expired");
        require(_currency == listing.currency, "Invalid currency");
        uint256 taxAmount = getTaxOnListing(_tokenAddress, _id);

        delete listings[address(_tokenAddress)][_id];
        listedTokenIDs[address(_tokenAddress)].remove(_id);
        _updateListedTokenTypes(_tokenAddress);

        _clearOffers(_tokenAddress, _id);

        IERC20Upgradeable(listing.currency).safeTransferFrom(msg.sender, taxRecipient, taxAmount);
        IERC20Upgradeable(listing.currency).safeTransferFrom(
            msg.sender,
            listing.seller,
            finalPrice.sub(taxAmount)
        );
        _tokenAddress.safeTransferFrom(address(this), msg.sender, _id);

        emit PurchasedListing(
            msg.sender,
            listing.seller,
            _tokenAddress,
            _id,
            finalPrice,
            listing.currency
        );
    }

    function purchasePackListing(
        IERC721 _tokenAddress,
        uint256 _packId,
        uint256 _maxPrice,
        IERC20Upgradeable _currency
    )
        external
        userNotBanned
        isPackListed(_tokenAddress, _packId)
    {
        (uint256 finalPrice,) = getPackFinalPrice(_tokenAddress, _packId);
        require(finalPrice <= _maxPrice, "Buying price too low");

        PackListing memory pack = packListings[address(_tokenAddress)][_packId];
        require(isUserBanned[pack.seller] == false, "Banned seller");
        require(block.timestamp >= pack.startingTime, "The order has not yet started");
        require(block.timestamp <= pack.expirationTime, "The order has expired");
        require(_currency == pack.currency, "Invalid currency");
        uint256 taxAmount = getPackTaxOnListing(_tokenAddress, _packId);

        delete packListings[address(_tokenAddress)][_packId];
        listedPackIDs[address(_tokenAddress)].remove(_packId);

        for (uint256 i = 0; i < pack.items.length; i++) {
            packListedTokenIDs[address(_tokenAddress)].remove(pack.items[i]);
            _tokenAddress.safeTransferFrom(address(this), msg.sender, pack.items[i]);
        }

        IERC20Upgradeable(pack.currency).safeTransferFrom(msg.sender, taxRecipient, taxAmount);
        IERC20Upgradeable(pack.currency).safeTransferFrom(
            msg.sender,
            pack.seller,
            finalPrice.sub(taxAmount)
        );

        _updateListedTokenTypes(_tokenAddress);

        emit PurchasedPackListing(
            msg.sender,
            pack.seller,
            _tokenAddress,
            _packId,
            finalPrice,
            pack.currency
        );
    }

    function offerListing(
        IERC721 _tokenAddress,
        uint256 _id,
        IERC20Upgradeable _currency,
        uint256 _price,
        uint256 _expirationTime
    )
        public
        userNotBanned
        isListed(_tokenAddress, _id)
    {
        bool isEnableOffering = getIsEnableOffering(_tokenAddress, _id);
        require(isEnableOffering, "Not allowed to offer");

        _checkRequirementsAndPerformOffer(_tokenAddress, _id, _currency, _price, _expirationTime);

        emit OfferListing(
            msg.sender,
            _tokenAddress,
            _id,
            _currency,
            _price,
            _expirationTime
        );
    }

    function _acceptOfferListing(
        IERC721 _tokenAddress,
        uint256 _id,
        address _offerer,
        uint256 _price,
        IERC20Upgradeable _currency
    ) internal returns(uint256) {
        require(isUserBanned[_offerer] == false, "Banned offerer");
        (IERC20Upgradeable currency, uint256 price, uint256 expirationTime) = getOfferDetail(_tokenAddress, _id, _offerer);
        _isAllowedCurrency(currency);
        require(block.timestamp <= expirationTime, "Offer time expired");
        require(currency == _currency, "Currency not match");
        require(price == _price, "Price not match");
        require(offerers[address(_tokenAddress)][_id].contains(_offerer), "Offerer not available");

        delete listings[address(_tokenAddress)][_id];
        listedTokenIDs[address(_tokenAddress)].remove(_id);
        _updateListedTokenTypes(_tokenAddress);

        uint256 taxAmount = getOfferTax(_tokenAddress, _id, _offerer);
        (uint256 finalPrice,) = getOfferFinalPrice(_tokenAddress, _id, _offerer);

        _clearOffers(_tokenAddress, _id); // Note: Get taxAmount and finalPrice before clear offers

        require(IERC20Upgradeable(currency).allowance(_offerer, address(this)) >= finalPrice, "Insufficient allowance");

        IERC20Upgradeable(currency).safeTransferFrom(_offerer, taxRecipient, taxAmount);
        IERC20Upgradeable(currency).safeTransferFrom(
            _offerer,
            msg.sender,
            finalPrice.sub(taxAmount)
        );
        _tokenAddress.safeTransferFrom(address(this), _offerer, _id);

        return finalPrice;
    }

    function acceptOfferListing(
        IERC721 _tokenAddress,
        uint256 _id,
        address _offerer,
        uint256 _price,
        IERC20Upgradeable _currency
    )
        public
        userNotBanned
        isListed(_tokenAddress, _id)
        isSeller(_tokenAddress, _id)
    {
        uint256 finalPrice = _acceptOfferListing(
            _tokenAddress,
            _id,
            _offerer,
            _price,
            _currency
        );

        emit AcceptOfferListing(
            msg.sender,
            _offerer,
            _tokenAddress,
            _id,
            _currency,
            finalPrice
        );
    }

    // function changeOffer(
    //     IERC721 _tokenAddress,
    //     uint256 _id,
    //     IERC20Upgradeable _newCurrency,
    //     uint256 _newPrice
    // )
    //     public
    //     userNotBanned
    // {
    //     _isAllowedCurrency(_newCurrency);
    //     require(_newPrice > 0, "Price too small");

    //     EnumerableSet.AddressSet storage _offerers = offerers[address(_tokenAddress)][_id];
    //     require(_offerers.contains(msg.sender), "Not offerer");

    //     offers[address(_tokenAddress)][_id][msg.sender].currency = _newCurrency;
    //     offers[address(_tokenAddress)][_id][msg.sender].price = _newPrice;

    //     emit OfferListingChange(
    //         msg.sender,
    //         _tokenAddress,
    //         _id,
    //         _newCurrency,
    //         _newPrice
    //     );
    // }

    function cancelOffer(IERC721 _tokenAddress, uint256 _id)
        public
        userNotBanned
    {
        EnumerableSet.AddressSet storage _offerers = offerers[address(_tokenAddress)][_id];
        require(_offerers.contains(msg.sender), "Not offerer");

        delete offers[address(_tokenAddress)][_id][msg.sender];
        _offerers.remove(msg.sender);

        emit CancelOfferListing(
            msg.sender,
            _tokenAddress,
            _id
        );
    }

    function setTaxRecipient(address _taxRecipient) public restricted {
        taxRecipient = _taxRecipient;
    }

    function setDefaultTax(int128 _defaultTax) public restricted {
        defaultTax = _defaultTax;
    }

    function setDefaultTaxAsRational(uint256 _numerator, uint256 _denominator)
        public
        restricted
    {
        defaultTax = ABDKMath64x64.divu(_numerator, _denominator);
    }

    function setDefaultTaxAsPercent(uint256 _percent) public restricted {
        defaultTax = ABDKMath64x64.divu(_percent, 100);
    }

    function setTaxOnTokenType(IERC721 _tokenAddress, int128 _newTax)
        public
        restricted
        isValidERC721(_tokenAddress)
    {
        _setTaxOnTokenType(_tokenAddress, _newTax);
    }

    function setTaxOnTokenTypeAsRational(
        IERC721 _tokenAddress,
        uint256 _numerator,
        uint256 _denominator
    ) public restricted isValidERC721(_tokenAddress) {
        _setTaxOnTokenType(
            _tokenAddress,
            ABDKMath64x64.divu(_numerator, _denominator)
        );
    }

    function setTaxOnTokenTypeAsPercent(
        IERC721 _tokenAddress,
        uint256 _percent
    ) public restricted isValidERC721(_tokenAddress) {
        _setTaxOnTokenType(
            _tokenAddress,
            ABDKMath64x64.divu(_percent, 100)
        );
    }

    function setUserBan(address user, bool to) public restricted {
        isUserBanned[user] = to;
    }

    function setUserBans(address[] memory users, bool to) public restricted {
        for(uint i = 0; i < users.length; i++) {
            isUserBanned[users[i]] = to;
        }
    }

    function allowToken(IERC721 _tokenAddress) public restricted isValidERC721(_tokenAddress) {
        allowedTokenTypes.add(address(_tokenAddress));
    }

    function disallowToken(IERC721 _tokenAddress) public restricted {
        allowedTokenTypes.remove(address(_tokenAddress));
    }

    function allowCurrency(IERC20Upgradeable _currency) public restricted {
        allowedCurrencies.add(address(_currency));
    }

    function disallowCurrency(IERC20Upgradeable _currency) public restricted {
        allowedCurrencies.remove(address(_currency));
    }

    function onERC721Received(
        address, /* operator */
        address, /* from */
        uint256 _id,
        bytes calldata /* data */
    ) external override returns (bytes4) {
        // NOTE: The contract address is always the message sender.
        address _tokenAddress = msg.sender;

        require(
            listedTokenTypes.contains(_tokenAddress) &&
                (
                    listedTokenIDs[_tokenAddress].contains(_id) ||
                    packListedTokenIDs[_tokenAddress].contains(_id)
                ),
            "Token ID not listed"
        );

        return IERC721ReceiverUpgradeable.onERC721Received.selector;
    }

    // ############
    // Internal helpers
    // ############
    function _setTaxOnTokenType(IERC721 tokenAddress, int128 newTax) private {
        require(newTax >= 0, "We're not running a charity here");
        tax[address(tokenAddress)] = newTax;
        freeTax[address(tokenAddress)] = newTax == 0;
    }

    function _updateListedTokenTypes(IERC721 tokenAddress) private {
        if (listedTokenIDs[address(tokenAddress)].length() > 0) {
            _registerTokenAddress(tokenAddress);
        } else {
            _unregisterTokenAddress(tokenAddress);
        }
    }

    function _registerTokenAddress(IERC721 tokenAddress) private {
        if (!listedTokenTypes.contains(address(tokenAddress))) {
            listedTokenTypes.add(address(tokenAddress));

            // this prevents resetting custom tax by removing all
            if (
                tax[address(tokenAddress)] == 0 && // unset or intentionally free
                freeTax[address(tokenAddress)] == false
            ) tax[address(tokenAddress)] = defaultTax;
        }
    }

    function _unregisterTokenAddress(IERC721 tokenAddress) private {
        listedTokenTypes.remove(address(tokenAddress));
    }

    function _clearOffers(IERC721 _tokenAddress, uint256 _id) private {
        EnumerableSet.AddressSet storage _offerers = offerers[address(_tokenAddress)][_id];
        for (uint256 i = 0; i < _offerers.length(); i++) {
            delete offers[address(_tokenAddress)][_id][_offerers.at(i)];
        }
        delete offerers[address(_tokenAddress)][_id];
    }

    function _checkRequirementsAndPerformOffer(
        IERC721 _tokenAddress,
        uint256 _id,
        IERC20Upgradeable _currency,
        uint256 _price,
        uint256 _expirationTime
    )
        private
    {
        _isAllowedCurrency(_currency);
        require(_price > 0, "Price too small");

        EnumerableSet.AddressSet storage _offerers = offerers[address(_tokenAddress)][_id];

        if (!_offerers.contains(msg.sender)) {
            _offerers.add(msg.sender);
            offers[address(_tokenAddress)][_id][msg.sender] = Offer(_currency, _price, _expirationTime);
        } else {
            offers[address(_tokenAddress)][_id][msg.sender].currency = _currency;
            offers[address(_tokenAddress)][_id][msg.sender].price = _price;
            offers[address(_tokenAddress)][_id][msg.sender].expirationTime = _expirationTime;
        }

        uint256 finalOfferPrice = _price.add(
            ABDKMath64x64.mulu(
                tax[address(_tokenAddress)],
                _price
            )
        );
        require(
            IERC20Upgradeable(_currency).balanceOf(msg.sender) >= finalOfferPrice,
            "Insufficient balance"
        );
    }
}