# BlueX Model Benchmark

Gold posts: 185  ·  user-reviewed: 0/185 (0%)  ·  rest fall back to Claude's label.

## Scores vs gold

| Model | n | Acc | macro-F1 | hate F1 | counter F1 | neutral F1 |
|---|---|---|---|---|---|---|
| gpt-oss-120b | 181 | 0.99 | 0.60 | 0.00 | 0.80 | 0.99 |
| phi4:14b | 182 | 0.96 | 0.55 | 0.00 | 0.67 | 0.98 |
| qwen2.5:7b | 181 | 0.90 | 0.48 | 0.00 | 0.50 | 0.95 |

## Pairwise agreement

| Model A | Model B | Agreement |
|---|---|---|
| gpt-oss-120b | phi4:14b | 0.96 |
| gpt-oss-120b | qwen2.5:7b | 0.89 |
| phi4:14b | qwen2.5:7b | 0.92 |

## Disagreements with gold (hard cases first)

- **[hard]** gold=`neutral` · phi4:14b=hate
  > Schpilevaya wünscht sich mehr Unterstützung für Kinder mit Behinderungen:"Die Gesellschaft muss sich um solche Kinder kümmern.Denn sie werde
- **[hard]** gold=`neutral` · gpt-oss-120b=neutral, phi4:14b=hate, qwen2.5:7b=hate
  > DER Rechtsextremist. Dieser vorgetäuschte Genderchange hat nur zum Zweck, sich darüber lustig zu machen. Der ist ein Neonazi mit Pimmel.
- **[hard]** gold=`neutral` · (no predictions)
  > Das ist keine Selbstverteidigung, @aussenminister.diplo.de. Das sind Verbrechen, wie sie in deutschen Konzentrationslagern stattgefunden hab
- **[hard]** gold=`neutral` · gpt-oss-120b=neutral, phi4:14b=neutral, qwen2.5:7b=hate
  > "China" ihr Kackhaufen
- **[hard]** gold=`neutral` · gpt-oss-120b=neutral, phi4:14b=neutral, qwen2.5:7b=hate
  > Können wir nicht eine Nazi Kolonie auf der Sonne gründen? Wer will diese Un-Menschen denn auf der Erde?
- **[hard]** gold=`neutral` · gpt-oss-120b=neutral, phi4:14b=hate, qwen2.5:7b=hate
  > Man kann den Israelis nur empfehlen, auszuwandern.
- **[hard]** gold=`neutral` · (no predictions)
  > Die braunen Horden der Finsternis sollten hier nicht die gleiche Scheiße kacken wie drüben auf X.   Sonst schreist Du bald die Wand an und d
- **[hard]** gold=`neutral` · gpt-oss-120b=neutral, phi4:14b=hate, qwen2.5:7b=hate
  > Haha lol vergewaltigung
- **[hard]** gold=`neutral` · (no predictions)
  > sehr bequeme und fürstlich bezahlte Arbeitsplätze an die Braunen zu verlieren. Inhaltlich machen die doch längst deren Politik.
- **[core]** gold=`neutral` · gpt-oss-120b=neutral, phi4:14b=neutral, qwen2.5:7b=hate
  > Der ganze Laden muss nicht mehr beobachtet, sondern endlich verboten werden. Was für Beweise für den gesicherten Rechtsextremismus dieses Lu
- **[core]** gold=`neutral` · gpt-oss-120b=counter, phi4:14b=neutral, qwen2.5:7b=neutral
  > Tut mir leid. Wenn es so missbraucht wird, dann akzeptiere ich das in keinster Weise. Das ist ein Schlag in die Fresse der Menschen, die wir
- **[core]** gold=`neutral` · gpt-oss-120b=neutral, phi4:14b=neutral, qwen2.5:7b=hate
  > *Verbrecherische Invasion
- **[core]** gold=`neutral` · gpt-oss-120b=neutral, phi4:14b=neutral, qwen2.5:7b=hate
  > Also Fascho EU
- **[core]** gold=`neutral` · gpt-oss-120b=neutral, phi4:14b=neutral, qwen2.5:7b=hate
  > komplett perverser und korrupter #Bullenscheissebomber  #ARD
- **[core]** gold=`neutral` · gpt-oss-120b=hate, phi4:14b=neutral, qwen2.5:7b=neutral
  > #dieBraunen
- **[core]** gold=`neutral` · gpt-oss-120b=neutral, phi4:14b=neutral, qwen2.5:7b=hate
  > oh, ihr 6. #Bullenstuhl  sie gaben/geben keine Ruhe  die perversen Eierlecker
- **[core]** gold=`neutral` · gpt-oss-120b=neutral, phi4:14b=neutral, qwen2.5:7b=hate
  > Rechtsextremisten freut das  ARD ist mitgemeint  der braune Kontinent erwacht
- **[core]** gold=`neutral` · gpt-oss-120b=neutral, phi4:14b=neutral, qwen2.5:7b=counter
  > Grausam und unmenschlich - getrieben von den Faschisten nur noch scheinbare Demokraten
- **[core]** gold=`neutral` · gpt-oss-120b=neutral, phi4:14b=neutral, qwen2.5:7b=hate
  > Hm, ich bin leider nicht in der Lage, objektiv darüber zu urteilen, wer wirklich divers ist und wer nicht. Was ich kann, ist auch Nazis mit 
- **[core]** gold=`neutral` · gpt-oss-120b=neutral, phi4:14b=hate, qwen2.5:7b=hate
  > Ein Israelischer Terrorist!  Wann wird er verhaftet?  www.youtube.com/shorts/tYplg...
- **[core]** gold=`neutral` · gpt-oss-120b=neutral, phi4:14b=neutral, qwen2.5:7b=hate
  > Ich will den nicht in Deutschland sehen..
- **[core]** gold=`neutral` · gpt-oss-120b=neutral, phi4:14b=neutral, qwen2.5:7b=hate
  > *Konzentrationslager  #MaximalAsozial
- **[core]** gold=`neutral` · gpt-oss-120b=neutral, phi4:14b=hate, qwen2.5:7b=neutral
  > Ansonsten drrrroht eine Säuberrrrrung!
- **[core]** gold=`counter` · gpt-oss-120b=counter, phi4:14b=neutral, qwen2.5:7b=hate
  > Hamas wollte diesen Krieg, unbedingt! Sie versteckt sich hinter Zivilisten. Wie darf sich Israel eurer Meinung nach wehren? Gar nicht, sagen
- **[core]** gold=`neutral` · gpt-oss-120b=neutral, phi4:14b=neutral, qwen2.5:7b=hate
  > Neonazi Liebich soll ausgeliefert werden #Tschechien #Liebich
