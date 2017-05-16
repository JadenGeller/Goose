{-# LANGUAGE MultiParamTypeClasses,
             TemplateHaskell,
             FlexibleInstances,
             UndecidableInstances,
             ViewPatterns #-}

import Prelude hiding (pi, (!!))
import Unbound.LocallyNameless
import Control.Monad.Trans.Maybe
import Control.Applicative
import Control.Monad.Except
import Control.Arrow

data Term = Type
          | Pi (Bind (Name Term, Embed Type) Term)
          | Var (Name Term) -- name indexed by what they refer to
          | App Term Term
          | Lambda (Bind (Name Term, Embed Type) Term)
          -- TODO: Add holes! Will probably require backtracking unification.
type Type = Term
      
--- Indexing

data IndexStep = AppFunc | AppArg | BindingType | BindingBody
  deriving Show
type Index =  [IndexStep]

(!!) :: LFresh m => Term -> Index -> m Term
(!!) term [] = return term
(!!) (App func _)  (AppFunc:index)     = func !! index
(!!) (App _ arg)   (AppArg:index)      = arg !! index
(!!) (Pi term)     (BindingType:index) = lunbind term $ \((_, unembed -> varType), _) -> varType !! index
(!!) (Pi term)     (BindingBody:index) = lunbind term $ \((_, _), body)               -> body    !! index
(!!) (Lambda term) (BindingType:index) = lunbind term $ \((_, unembed -> varType), _) -> varType !! index
(!!) (Lambda term) (BindingBody:index) = lunbind term $ \((_, _), body)               -> body    !! index
(!!) term (step:_) = error $ "index step " ++ show step ++ " not in " ++ show term

      
-- Unbound
                      
$(derive [''Term]) -- derivices boilerplate instances

instance Alpha Term

instance Subst Term Term where
    isvar (Var v) = Just (SubstName v)
    isvar _            = Nothing
 
-- Show

instance Show Term where
  show = runLFreshM . show'
      where show' :: LFresh m => Term -> m String
            show' Type = return "Type"
            show' (Pi term) = lunbind term $ \((varName, unembed -> varType), body) -> do
                varTypeString <- show' varType
                bodyString <- show' body
                if containsFree varName body
                  then return $ "(" ++ name2String varName ++ ":" ++ varTypeString ++ ") -> " ++ bodyString
                  else return $ wrapIfLoose varType varTypeString ++ " -> " ++ bodyString
            show' (Var name) = return $ name2String name
            show' (App func arg) = do
                funcString <- show' func
                argString <- show' arg
                return $ wrapIfLoose func funcString ++ " " ++ wrapIfLoose arg argString
            show' (Lambda term) = lunbind term $ \((varName, unembed -> varType), body) -> do
                varTypeString <- show' varType
                bodyString <- show' body
                return $ "λ" ++ name2String varName 
                      ++ ":" ++ wrapIfLoose varType varTypeString 
                      ++ "." ++ bodyString
            -- show' Hole = return "_"

            looselyBound :: Term -> Bool
            -- looselyBound Hole      = False
            looselyBound Type       = False
            looselyBound (Pi _)     = True
            looselyBound (Var _)    = False
            looselyBound (App _ _)  = True
            looselyBound (Lambda _) = True
            
            wrapIfLoose :: Term -> (String -> String)
            wrapIfLoose term | looselyBound term = \termString -> "(" ++ termString ++ ")"
                             | otherwise         = id

            containsFree :: Name Term -> Term -> Bool
            containsFree name term = name `elem` (fv term :: [Name Term])

-- Constructor
        
lambda :: String -> Type -> Term -> Term
lambda name typeAnnotation result = Lambda $ bind boundName result
    where boundName = ((string2Name name), embed typeAnnotation)

pi :: String -> Type -> Type -> Type
pi name typeAnnotation result = Pi $ bind boundName result
    where boundName = ((string2Name name), embed typeAnnotation)

(-->) :: Type -> Type -> Type
(-->) = pi "_"
infixr 9 -->

var :: String -> Term
var = Var . string2Name

(@@) :: Term -> Term -> Term
(@@) = App
infixl 9 @@

-- type checking
-- note: a mutually recursive design would be better in future

type Context = [(Name Term, Type)]

data TypeErrorReason = VariableNotInScope
                     | ExpectedFunction
                     | ExpectedTypeButFound Type Type
                     -- | UnableToInfer
    deriving Show

data TypeError = TypeError {
  index :: Index,
  reason :: TypeErrorReason
} deriving Show

type Stack = Index
          
prettyError :: Term -> TypeError -> String
prettyError term (TypeError index@(AppArg:index') (ExpectedTypeButFound expectedType foundType)) = 
    "Error:\n" ++ show index ++ "\n" ++ show term ++ "\n" ++
    "    • Couldn't match expected type ‘" ++ show expectedType ++ "’ with actual type ‘" ++ show foundType ++ "’\n" ++
    "    • In the argument of ‘" ++ show term ++ "’, namely ‘" ++ (show . runLFreshM) (term !! reverse index) ++ "’\n" ++
    "    • In the expression ‘" ++ (show . runLFreshM) (term !! reverse index')
prettyError _ _ = error "not implemented"
-- FIXME: Implement rest

elseThrowError :: Maybe a -> TypeError -> Except TypeError a
elseThrowError (Just x) _     = return x
elseThrowError Nothing  error = throwError error

check :: Index -> Context -> Type -> Term -> LFreshMT (Except TypeError) ()
-- check _ _ expectedType Infer = return expectedType
check index context expectedType term = do 
    foundType <- infer index context term
    if expectedType `aeq` foundType -- TODO: definitional eq
        then return ()
        else throwError $ TypeError index $ ExpectedTypeButFound expectedType foundType

-- Determine the type of a term
-- FIXME: Can we hide context in a monad?
-- FIXME: Can we report ALL errors instead of just the first?
infer :: Index -> Context -> Term -> LFreshMT (Except TypeError) Type

-- infer index _ Infer = throwError $ TypeError index UnableToInfer

-- Types have type "type".
-- This makes our language inconsistent as a logic
-- See: Girard's paradox
-- TODO: Use universes to make logic consistent.
infer _ _ Type = return Type

-- Check the type of a variable using the context.
-- TODO: Give a more informative error message.
infer index context (Var name) = lift $ 
    lookup name context `elseThrowError` TypeError index VariableNotInScope

infer index context (Lambda term) = lunbind term $ \((varName, unembed -> varType), body) -> do
    check (BindingType:index) context Type varType
    bodyType <- infer (BindingBody:index) ((varName, varType):context) body
    return $ Pi (bind (varName, embed varType) bodyType)

infer index context (Pi term) = lunbind term $ \((varName, unembed -> varType), body) -> do
    check (BindingType:index) context Type varType
    check (BindingBody:index) ((varName, varType):context) Type body
    return Type

infer index context (App func arg) = do
    expectedFuncType <- infer (AppFunc:index) context func
    case expectedFuncType of
        Pi funcType -> lunbind funcType $ \((varName, unembed -> varType), body) -> do
            check (AppArg:index) context varType arg
            return $ subst varName arg body
        _ -> throwError $ TypeError index ExpectedFunction -- TODO: args?

runInfer :: Term -> Except TypeError Type
runInfer term = runLFreshMT (infer [] [] term)

prettyRunInfer :: Term -> Either String Type
prettyRunInfer term = left (prettyError term) $ runExcept (runInfer term)

prettyRunInfer' :: Term -> IO ()
prettyRunInfer' term = case prettyRunInfer term of
                         Left error -> putStrLn error
                         Right inferredType -> putStrLn $ show inferredType

---- Small-step evaluation

step :: Term -> MaybeT LFreshM Term
-- step Infer      = error "invalid term" -- FIXME: build new valid term during typechecking
step Type       = mzero
step (Pi _)     = mzero
step (Var _)    = mzero
step (Lambda _) = mzero
step (App (Pi func) arg) = lunbind func $ \((varName, _), body) -> do
    return $ subst varName arg body
step (App (Lambda func) arg) = lunbind func $ \((varName, _), body) -> do
    return $ subst varName arg body
step (App func arg) = (step func >>= \func' -> return $ App func' arg)
                  <|> (step arg  >>= \arg'  -> return $ App func arg')

reduce :: Term -> LFreshM Term
reduce term = do
        result <- runMaybeT (step term)
        case result of
            Just term' -> reduce term'
            Nothing -> return term

eval :: Term -> Term
eval term = runLFreshM (reduce term)
--

---- Example

id' = lambda "t" Type $ 
          lambda "x" (var "t") $ 
              var "x"

bool' = pi "t" Type $ 
            var "t" --> var "t" --> var "t"

true' = lambda "t" Type $
            lambda "x" (var "t") $
                lambda "y" (var "t") $
                    var "x"
                    
false' = lambda "t" Type $
             lambda "x" (var "t") $
                 lambda "y" (var "t") $
                     var "y"

cond' = lambda "b" bool' $
            var "b"

not' = lambda "b" bool' $
           cond' @@ var "b" @@ bool' @@ false' @@ true' 
          
and' = lambda "p" Type $
           lambda "q" Type $
               pi "t" Type $
                   (var "p" --> var "q" --> var "t") --> var "t"

conj' = lambda "p" Type $
            lambda "q" Type $
                lambda "x" (var "p") $
                    lambda "y" (var "q") $
                        lambda "t" Type $
                            lambda "f" (var "p" --> var "q" --> var "t") $
                                var "f" @@ var "x" @@ var "y"

--
---- BoolType
--program = (Application
--              (Application
--                  (lambda "x" BoolType $
--                      lambda "y" UnitType $
--                          var "x")
--                  (BoolLiteral False))
--              Unit)
--
