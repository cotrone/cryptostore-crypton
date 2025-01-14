-- |
-- Module      : Crypto.Store.CMS.Signed
-- License     : BSD-style
-- Maintainer  : Olivier Chéron <olivier.cheron@gmail.com>
-- Stability   : experimental
-- Portability : unknown
--
--
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RecordWildCards #-}
module Crypto.Store.CMS.Signed
    ( EncapsulatedContent
    , SignedData(..)
    , SignerInfo(..)
    , SignerIdentifier(..)
    , IssuerAndSerialNumber(..)
    , ProducerOfSI
    , ConsumerOfSI
    , certSigner
    , withPublicKey
    , withSignerKey
    , withSignerCertificate
    , encapsulatedContentInfoASN1S
    , parseEncapsulatedContentInfo
    ) where

import Control.Applicative
import Control.Monad

import           Data.ASN1.Types
import           Data.ByteString (ByteString)
import qualified Data.ByteString as B
import           Data.Hourglass
import           Data.List
import           Data.Maybe
import           Data.X509

import Crypto.Random (MonadRandom)

import Crypto.Store.ASN1.Generate
import Crypto.Store.ASN1.Parse
import Crypto.Store.CMS.Algorithms
import Crypto.Store.CMS.AuthEnveloped
import Crypto.Store.CMS.Attribute
import Crypto.Store.CMS.Enveloped
import Crypto.Store.CMS.OriginatorInfo
import Crypto.Store.CMS.Type
import Crypto.Store.CMS.Util
import Crypto.Store.Error

-- | Encapsulated content.
type EncapsulatedContent = ByteString

-- | Information related to a signer of a 'Crypto.Store.CMS.SignedData'.  An
-- element contains the signature material that was produced.
data SignerInfo = SignerInfo
    { siSignerId :: SignerIdentifier
      -- ^ Identifier of the signer certificate
    , siDigestAlgorithm :: DigestAlgorithm
      -- ^ Digest algorithm used for the signature
    , siSignedAttrs :: [Attribute]
      -- ^ Optional signed attributes
    , siSignatureAlg :: SignatureAlg
      -- ^ Algorithm used for signature
    , siSignature :: SignatureValue
      -- ^ The signature value
    , siUnsignedAttrs :: [Attribute]
      -- ^ Optional unsigned attributes
    }
    deriving (Show,Eq)

instance ASN1Elem e => ProduceASN1Object e SignerInfo where
    asn1s SignerInfo{..} =
        asn1Container Sequence (ver . sid . dig . sa . alg . sig . ua)
      where
        ver = gIntVal (getVersion siSignerId)
        sid = asn1s siSignerId
        dig = algorithmASN1S Sequence siDigestAlgorithm
        sa  = attributesASN1S (Container Context 0) siSignedAttrs
        alg = algorithmASN1S Sequence siSignatureAlg
        sig = gOctetString siSignature
        ua  = attributesASN1S (Container Context 1) siUnsignedAttrs

instance Monoid e => ParseASN1Object e SignerInfo where
    parse = onNextContainer Sequence $ do
        IntVal v <- getNext
        when (v /= 1 && v /= 3) $
            throwParseError ("SignerInfo: parsed invalid version: " ++ show v)
        sid <- parse
        dig <- parseAlgorithm Sequence
        sAttrs <- parseAttributes (Container Context 0)
        alg <- parseAlgorithm Sequence
        OctetString sig <- getNext
        uAttrs <- parseAttributes (Container Context 1)
        return SignerInfo { siSignerId = sid
                          , siDigestAlgorithm = dig
                          , siSignedAttrs = sAttrs
                          , siSignatureAlg = alg
                          , siSignature = sig
                          , siUnsignedAttrs = uAttrs
                          }

getVersion :: SignerIdentifier -> Integer
getVersion (SignerIASN _) = 1
getVersion (SignerSKI _)  = 3

-- | Return true when the signer info has version 3.
isVersion3 :: SignerInfo -> Bool
isVersion3 = (== 3) . getVersion . siSignerId

-- | Union type related to identification of the signer certificate.
data SignerIdentifier
    = SignerIASN IssuerAndSerialNumber  -- ^ Issuer and Serial Number
    | SignerSKI  ByteString             -- ^ Subject Key Identifier
    deriving (Show,Eq)

instance ASN1Elem e => ProduceASN1Object e SignerIdentifier where
    asn1s (SignerIASN iasn) = asn1s iasn
    asn1s (SignerSKI  ski)  = asn1Container (Container Context 0)
                                  (gOctetString ski)

instance Monoid e => ParseASN1Object e SignerIdentifier where
    parse = parseIASN <|> parseSKI
      where parseIASN = SignerIASN <$> parse
            parseSKI  = SignerSKI  <$>
                onNextContainer (Container Context 0) parseOctetStringPrim

-- | Try to find a certificate with the specified identifier.
findSigner :: SignerIdentifier
           -> [SignedCertificate]
           -> Maybe (SignedCertificate, [SignedCertificate])
findSigner (SignerIASN iasn) certs =
    partitionHead (matchIASN . signedObject . getSigned) certs
  where
    matchIASN c =
        (iasnIssuer iasn, iasnSerial iasn) == (certIssuerDN c, certSerial c)
findSigner (SignerSKI  ski) certs =
    partitionHead (matchSKI. signedObject . getSigned) certs
  where
    matchSKI c =
        case extensionGet (certExtensions c) of
            Just (ExtSubjectKeyId idBs) -> idBs == ski
            Nothing                     -> False

partitionHead :: (a -> Bool) -> [a] -> Maybe (a, [a])
partitionHead p l =
    case partition p l of
        (x : _, r) -> Just (x, r)
        ([]   , _)    -> Nothing

-- | Function able to produce a 'SignerInfo'.
type ProducerOfSI m = ContentType -> ByteString -> m (Either StoreError (SignerInfo, [CertificateChoice], [RevocationInfoChoice]))

-- | Function able to consume a 'SignerInfo'.
type ConsumerOfSI m = ContentType -> ByteString -> SignerInfo -> [CertificateChoice] -> [RevocationInfoChoice] -> m Bool

-- | Create a signer info with the specified signature algorithm and
-- credentials.
--
-- Two lists of optional attributes can be provided.  The attributes will be
-- part of message signature when provided in the first list.
--
-- When the first list of attributes is provided, even empty list, signature is
-- computed from a digest of the content.  When the list of attributes is
-- 'Nothing', no intermediate digest is used and the signature is computed from
-- the full message.
certSigner :: MonadRandom m
           => SignatureAlg
           -> PrivKey
           -> CertificateChain
           -> Maybe [Attribute]
           -> [Attribute]
           -> ProducerOfSI m
certSigner alg priv (CertificateChain chain) sAttrsM uAttrs ct msg =
    fmap build <$> generate
  where
    md   = digest dig msg
    def  = DigestAlgorithm Crypto.Store.CMS.Algorithms.SHA256
    cert = head chain
    obj  = signedObject (getSigned cert)
    isn  = IssuerAndSerialNumber (certIssuerDN obj) (certSerial obj)
    pub  = certPubKey obj

    (dig, alg') = signatureResolveHash noAttr def alg

    noAttr          = null sAttrs
    (sAttrs, input) =
        case sAttrsM of
            Nothing    -> ([], msg)
            Just attrs ->
                let l = setContentTypeAttr ct $ setMessageDigestAttr md attrs
                 in (l, encodeAuthAttrs l)

    generate  = signatureGenerate alg' priv pub input
    build sig =
        let si = SignerInfo { siSignerId = SignerIASN isn
                            , siDigestAlgorithm = dig
                            , siSignedAttrs = sAttrs
                            , siSignatureAlg = alg
                            , siSignature = sig
                            , siUnsignedAttrs = uAttrs
                            }
         in (si, map CertificateCertificate chain, [])

-- | Verify that the signature was produced from the specified public key.
-- Ignores all certificates and CRLs contained in the signed data.
withPublicKey :: Applicative f => PubKey -> ConsumerOfSI f
withPublicKey pub ct msg SignerInfo{..} _ _ = pure $
    fromMaybe False $ do
        guard (noAttr || attrMatch)
        guard mdAccept
        alg <- signatureCheckHash siDigestAlgorithm siSignatureAlg
        return (signatureVerify alg pub input siSignature)
  where
    noAttr    = null siSignedAttrs
    mdMatch   = mdAttr == Just (digest siDigestAlgorithm msg)
    attrMatch = ctAttr == Just ct && mdMatch
    mdAttr    = getMessageDigestAttr siSignedAttrs
    mdAccept  = securityAcceptable siDigestAlgorithm
    ctAttr    = getContentTypeAttr siSignedAttrs
    input     = if noAttr then msg else encodeAuthAttrs siSignedAttrs

-- | Verify that the signature is valid with one of the X.509 certificates
-- contained in the signed data, but does not validate that the certificates are
-- valid.  All transmitted certificates are implicitely trusted and all CRLs are
-- ignored.
withSignerKey :: Applicative f => ConsumerOfSI f
withSignerKey = withSignerCertificate (\_ _ -> pure True)

-- | Verify that the signature is valid with one of the X.509 certificates
-- contained in the signed data, and verify that the signer certificate is valid
-- using the validation function supplied.  All CRLs are ignored.
withSignerCertificate :: Applicative f
                      => (Maybe DateTime -> CertificateChain -> f Bool)
                      -> ConsumerOfSI f
withSignerCertificate validate ct msg SignerInfo{..} certs crls =
    case getCertificateChain of
        Just chain -> validate mSigningTime chain
        Nothing    -> pure False
  where
    getCertificateChain = do
        (cert, others) <- findSigner siSignerId x509Certificates
        let pub = certPubKey $ signedObject $ getSigned cert
        validSignature <- withPublicKey pub ct msg SignerInfo{..} certs crls
        guard validSignature
        return $ CertificateChain (cert : others)

    mSigningTime = getSigningTimeAttr siSignedAttrs

    x509Certificates = mapMaybe asX509 certs

    asX509 (CertificateCertificate c) = Just c
    asX509 _                          = Nothing

-- | Signed content information.
data SignedData content = SignedData
    { sdDigestAlgorithms :: [DigestAlgorithm]      -- ^ Digest algorithms
    , sdContentType :: ContentType                 -- ^ Inner content type
    , sdEncapsulatedContent :: content             -- ^ Encapsulated content
    , sdCertificates :: [CertificateChoice]        -- ^ The collection of certificates
    , sdCRLs  :: [RevocationInfoChoice]            -- ^ The collection of CRLs
    , sdSignerInfos :: [SignerInfo]                -- ^ Per-signer information
    }
    deriving (Show,Eq)

instance ProduceASN1Object ASN1P (SignedData (Encap EncapsulatedContent)) where
    asn1s SignedData{..} =
        asn1Container Sequence (ver . dig . ci . certs . crls . sis)
      where
        ver = gIntVal v
        dig = asn1Container Set (digestTypesASN1S sdDigestAlgorithms)
        ci  = encapsulatedContentInfoASN1S sdContentType sdEncapsulatedContent
        certs = gen 0 sdCertificates
        crls  = gen 1 sdCRLs
        sis = asn1Container Set (asn1s sdSignerInfos)

        gen tag list
            | null list = id
            | otherwise = asn1Container (Container Context tag) (asn1s list)

        v | hasChoiceOther sdCertificates = 5
          | hasChoiceOther sdCRLs         = 5
          | any isVersion3 sdSignerInfos  = 3
          | sdContentType == DataType     = 1
          | otherwise                     = 3


instance ParseASN1Object [ASN1Event] (SignedData (Encap EncapsulatedContent)) where
    parse =
        onNextContainer Sequence $ do
            IntVal v <- getNext
            when (v > 5) $
                throwParseError ("SignedData: parsed invalid version: " ++ show v)
            dig <- onNextContainer Set parseDigestTypes
            (ct, bs) <- parseEncapsulatedContentInfo
            certs <- parseOptList 0
            crls  <- parseOptList 1
            sis <- onNextContainer Set parse
            return SignedData { sdDigestAlgorithms = dig
                              , sdContentType = ct
                              , sdEncapsulatedContent = bs
                              , sdCertificates = certs
                              , sdCRLs = crls
                              , sdSignerInfos = sis
                              }
      where
        parseOptList tag =
            fromMaybe [] <$> onNextContainerMaybe (Container Context tag) parse

-- | Generate ASN.1 for EncapsulatedContentInfo.
encapsulatedContentInfoASN1S :: ASN1Elem e => ContentType -> Encap EncapsulatedContent -> ASN1Stream e
encapsulatedContentInfoASN1S ct ec = asn1Container Sequence (oid . cont)
  where oid = gOID (getObjectID ct)
        cont = encapsulatedASN1S (Container Context 0) ec

encapsulatedASN1S :: ASN1Elem e
                  => ASN1ConstructionType -> Encap B.ByteString -> ASN1Stream e
encapsulatedASN1S _   Detached     = id
encapsulatedASN1S ty (Attached bs) = asn1Container ty (gOctetString bs)

-- | Parse EncapsulatedContentInfo from ASN.1.
parseEncapsulatedContentInfo :: Monoid e => ParseASN1 e (ContentType, Encap EncapsulatedContent)
parseEncapsulatedContentInfo =
    onNextContainer Sequence $ do
        OID oid <- getNext
        withObjectID "content type" oid $ \ct ->
            wrap ct <$> onNextContainerMaybe (Container Context 0) parseOctetString
  where
    wrap ct Nothing  = (ct, Detached)
    wrap ct (Just c) = (ct, Attached c)

digestTypesASN1S :: ASN1Elem e => [DigestAlgorithm] -> ASN1Stream e
digestTypesASN1S list cont = foldr (algorithmASN1S Sequence) cont list

parseDigestTypes :: Monoid e => ParseASN1 e [DigestAlgorithm]
parseDigestTypes = getMany (parseAlgorithm Sequence)
