import React from 'react';
import {interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {ChannelVariant, getChannelCopy} from '../channelCopy';
import {SceneContainer} from '../components/SceneContainer';
import {colors, fonts} from '../theme';

export const Scene9Cost: React.FC<{
	durationInFrames?: number;
	channelVariant?: ChannelVariant;
}> = ({durationInFrames, channelVariant = 'esafe'}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const channelCopy = getChannelCopy(channelVariant);
	const left = spring({fps, frame, config: {damping: 16, stiffness: 120}, durationInFrames: 24});
	const right = spring({
		fps,
		frame: Math.max(0, frame - 4),
		config: {damping: 16, stiffness: 120},
		durationInFrames: 24,
	});
	const footerOpacity = interpolate(frame, [190, 230], [0, 1], {
		extrapolateLeft: 'clamp',
		extrapolateRight: 'clamp',
	});

	return (
		<SceneContainer durationInFrames={durationInFrames}>
			<div
				style={{
					flex: 1,
					display: 'flex',
					flexDirection: 'column',
					alignItems: 'center',
					justifyContent: 'center',
					padding: '0 96px',
					gap: 28,
				}}
			>
				<div
					style={{
						display: 'flex',
						flexDirection: 'column',
						alignItems: 'center',
						gap: 10,
						marginBottom: 8,
					}}
				>
					<div
						style={{
							fontFamily: fonts.body,
							fontSize: 18,
							letterSpacing: 2.5,
							textTransform: 'uppercase',
							color: colors.inkSoft,
						}}
					>
						Closing the gap in your security stack
					</div>
					<div
						style={{
							fontFamily: fonts.headline,
							fontSize: 50,
							fontWeight: 800,
							color: colors.text,
							textAlign: 'center',
						}}
					>
						One voice clone incident can average a $500,000 loss.
					</div>
				</div>
				<div
					style={{
						display: 'grid',
						gridTemplateColumns: '1fr auto 1fr',
						alignItems: 'start',
						gap: 30,
						width: '100%',
						maxWidth: 1480,
						paddingTop: 18,
						borderTop: `1px solid ${colors.border}`,
					}}
				>
					<div
						style={{
							padding: '18px 18px 18px 0',
							transform: `translateX(${interpolate(left, [0, 1], [-60, 0])}px)`,
							opacity: left,
							filter: `blur(${interpolate(left, [0, 1], [8, 0])}px)`,
						}}
					>
						<div
							style={{
								fontFamily: fonts.headline,
								fontSize: 15,
								letterSpacing: 2,
								color: colors.danger,
								marginBottom: 18,
								fontWeight: 800,
							}}
						>
							WITHOUT PROTECTION
						</div>
						<div
							style={{
								fontFamily: fonts.body,
								fontSize: 28,
								fontWeight: 700,
								color: colors.text,
								marginBottom: 16,
							}}
						>
							The Risk
						</div>
						<div style={{fontFamily: fonts.headline, fontSize: 84, color: colors.danger, fontWeight: 800}}>
							$500,000
						</div>
						<div style={{fontFamily: fonts.body, fontSize: 22, color: colors.muted, marginBottom: 22}}>
							average loss
						</div>
						<div
							style={{
								fontFamily: fonts.body,
								fontSize: 21,
								color: colors.muted,
								lineHeight: 1.45,
								maxWidth: 430,
							}}
						>
							One voice clone incident can create a six-figure hit before anyone realizes
							what happened.
						</div>
					</div>
					<div
						style={{
							width: 1,
							alignSelf: 'stretch',
							background: colors.border,
							opacity: Math.min(left, right),
						}}
					/>
					<div
						style={{
							padding: '18px 0 18px 18px',
							transform: `translateX(${interpolate(right, [0, 1], [60, 0])}px)`,
							opacity: right,
							filter: `blur(${interpolate(right, [0, 1], [8, 0])}px)`,
						}}
					>
						<div
							style={{
								fontFamily: fonts.headline,
								fontSize: 15,
								letterSpacing: 2,
								color: colors.safe,
								marginBottom: 18,
								fontWeight: 800,
							}}
						>
							WITH VICALL
						</div>
						<div
							style={{
								fontFamily: fonts.body,
								fontSize: 28,
								fontWeight: 700,
								color: colors.text,
								marginBottom: 16,
							}}
						>
							The Solution
						</div>
						<div style={{fontFamily: fonts.headline, fontSize: 84, color: colors.safe, fontWeight: 800}}>
							$1.12
						</div>
						<div style={{fontFamily: fonts.body, fontSize: 22, color: colors.muted, marginBottom: 22}}>
							less than your daily coffee
						</div>
						<div
							style={{
								fontFamily: fonts.body,
								fontSize: 21,
								color: colors.muted,
								lineHeight: 1.45,
								maxWidth: 430,
							}}
						>
							ViCall protection works out to $1.12 a day per employee. Overage is billed at
							$0.011 per minute after 450 minutes, through the MSP.
						</div>
					</div>
				</div>
				<div
					style={{
						display: 'flex',
						flexDirection: 'column',
						alignItems: 'center',
						gap: 14,
						opacity: footerOpacity,
					}}
				>
					<div
						style={{
							display: 'flex',
							alignItems: 'center',
							gap: 18,
							fontFamily: fonts.body,
							fontSize: 21,
							color: colors.text,
							fontWeight: 600,
						}}
					>
						<div>Protection starts at $35/seat/month</div>
						<div style={{width: 1, height: 18, background: colors.border}} />
						<div>+$0.011/min after 450 minutes</div>
					</div>
					<div
						style={{
							fontFamily: fonts.body,
							fontWeight: 600,
							fontSize: 28,
							lineHeight: 1.3,
							color: colors.text,
							textAlign: 'center',
							maxWidth: 1280,
						}}
					>
						{channelCopy.scene9Footer}
					</div>
					<div
						style={{
							fontFamily: fonts.body,
							fontSize: 16,
							color: colors.muted,
							textAlign: 'center',
						}}
					>
						*Source: AI Voice Cloning Fraud Statistics 2026 Report
					</div>
				</div>
			</div>
		</SceneContainer>
	);
};
